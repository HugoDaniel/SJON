/**
 * The visitor-facing half of "the language server did not start".
 *
 * Total LSP boot failure used to be reported to `console.error` and nowhere
 * else, which is the worst shape a failure can take here: the editor still
 * mounts, still highlights, still lets you type — and the diagnostics gutter,
 * the outline, and the values panel are simply, permanently empty. Nothing on
 * screen distinguishes that from a document that happens to be valid and
 * uninteresting. The one incident this playground has had was exactly this
 * class (both backends died on a `Content-Type` header; see wasm-compile.ts),
 * and it was found by a human squinting at a live page, not by any gate.
 *
 * So: say it out loud, and say what still works. Structural types rather than
 * `HTMLElement` so the whole path is reachable from `node:test` without a DOM
 * — a real element satisfies them, and `lsp-failure.test.ts` drives the same
 * function with a two-field stand-in.
 */

/** The `textContent` sink for the failure reason. */
export interface ReasonSlot {
  textContent: string | null;
}

/**
 * The banner element: hideable, and able to find its own reason slot.
 *
 * `hidden` is `boolean | string` rather than `boolean` because that is what
 * lib.dom says — the attribute also takes `"until-found"`. We only ever write
 * `false` to it.
 */
export interface FailureBanner {
  hidden: boolean | string;
  querySelector(selectors: string): ReasonSlot | null;
}

/** Marks the banner in `playground.astro`. */
export const FAILURE_BANNER_SELECTOR = '[data-pg-lsp-failed]';

/** Marks the element inside it that receives the reason text. */
export const FAILURE_REASON_SELECTOR = '[data-pg-lsp-failed-reason]';

/**
 * Shorten an unknown thrown value to one line a visitor can paste into a bug
 * report. Engine messages here are already short and specific ("Incorrect
 * response MIME type"), so the message alone carries the diagnosis; the stack
 * goes to the console, which is where a developer will look anyway.
 */
export function describeLspFailure(error: unknown): string {
  if (error instanceof Error && error.message) return error.message;
  const text = String(error);
  return text === '[object Object]' ? 'unknown error' : text;
}

/**
 * Unhide the failure banner and fill in its reason slot.
 *
 * Tolerates a missing banner and a missing slot: this runs inside a `catch`
 * that has already lost the language server, and throwing a second time
 * there would take down the editor mount that survived. A caller passing
 * `null` (banner absent from the markup) is a no-op by design — the console
 * line at the call site is still emitted.
 */
export function showLspFailure(banner: FailureBanner | null, error: unknown): void {
  if (!banner) return;
  const slot = banner.querySelector(FAILURE_REASON_SELECTOR);
  if (slot) slot.textContent = describeLspFailure(error);
  banner.hidden = false;
}
