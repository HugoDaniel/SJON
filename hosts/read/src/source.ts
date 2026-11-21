// Byte view over one JS source string.
//
// SJON spans are half-open **UTF-8 byte** ranges while JS strings are UTF-16
// code units. Every reader entry point encodes the input exactly once with
// `TextEncoder` semantics — a lone surrogate becomes U+FFFD, which is what a
// host would actually emit — and everything downstream (lexer, parser, spans)
// works on bytes. Decoding is confined to node *values*: `decodeRange` is only
// called on complete lexemes, never to compute an offset.

const encoder = new TextEncoder();
const decoder = new TextDecoder();

/** Encode a JS source string with `TextEncoder` semantics. Complexity O(n). */
export function encodeSource(source: string): Uint8Array {
  return encoder.encode(source);
}

/**
 * Decode one half-open byte range to its JS string value.
 *
 * Callers pass token bodies and value spans, whose boundaries always fall on
 * code-point edges; the decoder is non-fatal so a stray fragment becomes
 * U+FFFD instead of throwing. Complexity O(end - start).
 */
export function decodeRange(bytes: Uint8Array, start: number, end: number): string {
  return decoder.decode(bytes.subarray(start, end));
}
