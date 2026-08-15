/**
 * Best-effort message extraction from an unknown thrown value. Prefers a
 * `.message` string (the `Error` shape) and falls back to `String(err)`.
 * Shared by `SjonHost` (WASM/resolver bridge failures) and
 * `createNodeFsResolver` (fs / parse failures).
 */
export function errMsg(err: unknown): string {
  if (err && typeof err === 'object' && 'message' in err) {
    return (err as { message: string }).message;
  }
  return String(err);
}
