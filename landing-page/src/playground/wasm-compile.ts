/**
 * Compile a fetched wasm response, streaming it only when the host allows.
 *
 * `WebAssembly.compileStreaming` refuses any response whose `Content-Type` is
 * not `application/wasm` — and plenty of static hosts do not set it. The
 * published playground at https://hugodaniel.com/pages/sjon/playground was
 * dead on arrival for exactly this reason: that server sends
 * `application/octet-stream` for `.wasm`, so the boot failed with
 * *"Incorrect response MIME type"* before the language server ever started.
 * Nothing local could see it — `astro dev` and `astro preview` both serve the
 * correct type.
 *
 * So: stream where the header permits it, and fall back to buffering the body
 * where it does not. Streaming stays the fast path on a correctly-configured
 * host; a misconfigured one costs one full buffer instead of the whole
 * playground.
 *
 * Deciding off the header rather than catching the rejection is deliberate.
 * `compileStreaming` consumes the response body as it reads it, so a retry in
 * the catch would need a second `fetch` — and the message it throws is
 * engine-specific text, which is a poor thing to branch on.
 */
export async function compileWasmResponse(response: Response): Promise<WebAssembly.Module> {
  if (!response.ok) {
    // The url already names the artifact, so the message does not hard-code
    // one — and this text is visitor-facing now, via `showLspFailure`.
    throw new Error(`wasm fetch failed: ${response.url || '(no url)'} → HTTP ${response.status}`);
  }
  if (canStream(response.headers.get('content-type'))) {
    return WebAssembly.compileStreaming(response);
  }
  return WebAssembly.compile(await response.arrayBuffer());
}

/**
 * Whether every engine will let `compileStreaming` read this `Content-Type`.
 *
 * The test is exact, and deliberately narrower than the spec: the spec says to
 * match the media type's essence case-insensitively and to allow parameters,
 * but engines disagree — Node rejects `Application/Wasm; charset=binary`
 * outright, which a unit test here caught. Since the fallback is only the cost
 * of buffering, being wrong in the strict direction is free and being wrong in
 * the permissive direction is the bug we are fixing. Servers that set the type
 * at all send exactly this string.
 */
function canStream(header: string | null): boolean {
  return header?.trim() === 'application/wasm';
}
