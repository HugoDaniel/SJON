// The diagnostic catalogue, read from the generated
// `src/data/errors.json` (emitted from `src/Explanations.zig` by
// `zig build gen-explanations` — never hand-edit it).
//
// The prose in that file is Zig source-wrapped plain text with markdown
// inline code: paragraphs separated by blank lines, hard-wrapped at ~65
// columns, `backticks` around code. The helpers below turn that into
// HTML — reflowing the hard wraps and honouring the backticks — rather
// than pulling in a markdown renderer for two constructs.

import data from '../data/errors.json';

export interface ErrorEntry {
  code: string;
  /** One-line summary. Always present. */
  short: string;
  /** Multi-paragraph body. Empty when the summary suffices. */
  long: string;
}

export const ERRORS: readonly ErrorEntry[] = data;

const HTML_ESCAPES: Record<string, string> = {
  '&': '&amp;',
  '<': '&lt;',
  '>': '&gt;',
  '"': '&quot;',
};

function escapeHtml(text: string): string {
  return text.replace(/[&<>"]/g, (c) => HTML_ESCAPES[c] ?? c);
}

/**
 * Escape `text` for HTML, then render `` `code` `` spans as `<code>`.
 *
 * Escaping runs first so a `<` in the prose can never open a tag, and the
 * `<code>` markers this adds afterwards are the only markup in the result.
 */
export function inlineMarkup(text: string): string {
  return escapeHtml(text).replace(/`([^`]+)`/g, '<code>$1</code>');
}

/**
 * Split a `long` body into paragraphs, reflowing each one's hard wraps
 * into a single line. Returns an empty array for an empty body.
 */
export function paragraphs(long: string): string[] {
  if (!long) return [];
  return long
    .split(/\n\s*\n/)
    .map((para) => para.split('\n').join(' ').trim())
    .filter((para) => para.length > 0);
}
