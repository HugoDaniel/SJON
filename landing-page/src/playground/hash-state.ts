/**
 * URL-hash codec for the playground's shareable state.
 *
 * Format: `#k=v&k=v`. `s` is the document, `sc` is a base64url-encoded JSON
 * array of schema texts. The bare `#s=<doc>` form that tutorial deep-links
 * use still decodes (single key, no `sc`).
 *
 * Lifted out of `boot.ts` so it can be exercised without a DOM: `boot.ts`
 * transitively imports Astro's `import.meta.env`, which a plain `node --test`
 * run cannot evaluate. Everything here is pure — `decodeHashState` takes the
 * hash string rather than reading `window.location`, so the caller owns the
 * one impure step.
 */

/** Encode a string as unpadded, URL-safe base64 (UTF-8 bytes). */
export function b64urlEncode(s: string): string {
  // Percent-encode to UTF-8 bytes, then base64, then URL-safe + unpadded.
  const utf8 = encodeURIComponent(s).replace(/%([0-9A-F]{2})/g, (_m, h: string) =>
    String.fromCharCode(parseInt(h, 16)),
  );
  return btoa(utf8).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
}

/** Inverse of {@link b64urlEncode}. Throws on malformed input. */
export function b64urlDecode(s: string): string {
  const b64 = s.replace(/-/g, '+').replace(/_/g, '/');
  const padded = b64 + '='.repeat((4 - (b64.length % 4)) % 4);
  const bytes = atob(padded);
  return decodeURIComponent(
    Array.from(bytes, (c) => '%' + c.charCodeAt(0).toString(16).padStart(2, '0')).join(''),
  );
}

export interface HashState {
  doc: string | null;
  schemas: string[];
}

/**
 * Parse `#s=…&sc=…` into document + schema texts. A leading `#` is optional.
 * Malformed components are skipped rather than thrown — a truncated share
 * link should degrade to the default sample, not to a broken page.
 */
export function decodeHashState(hash: string): HashState {
  const state: HashState = { doc: null, schemas: [] };
  const body = hash.replace(/^#/, '');
  if (!body) return state;
  for (const part of body.split('&')) {
    const eq = part.indexOf('=');
    if (eq < 0) continue;
    const key = part.slice(0, eq);
    const value = part.slice(eq + 1);
    try {
      if (key === 's') {
        state.doc = b64urlDecode(value);
      } else if (key === 'sc') {
        const parsed: unknown = JSON.parse(b64urlDecode(value));
        if (Array.isArray(parsed)) {
          state.schemas = parsed.filter((x): x is string => typeof x === 'string');
        }
      }
    } catch {
      /* malformed component — ignore, fall back to defaults */
    }
  }
  return state;
}

/** Build the hash body (no leading `#`) for a document + schema set. */
export function encodeHashState(doc: string, schemaTexts: readonly string[]): string {
  let hash = 's=' + b64urlEncode(doc);
  if (schemaTexts.length > 0) {
    hash += '&sc=' + b64urlEncode(JSON.stringify(schemaTexts));
  }
  return hash;
}
