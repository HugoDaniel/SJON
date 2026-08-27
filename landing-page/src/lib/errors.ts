// The diagnostic catalogue, read from the generated
// `src/data/errors.json` (emitted from `src/Explanations.zig` by
// `zig build gen-explanations` — never hand-edit it).
//
// The prose in that file is markdown: paragraphs separated by blank lines,
// hard-wrapped at ~65 columns, backticks around code, and — in a few entries —
// fenced blocks and bullet lists. `src/lib/docs-loader.ts` feeds it to the
// site's markdown pipeline, so this module is now just the typed read.

import data from '../data/errors.json';

export interface ErrorEntry {
  code: string;
  /** One-line summary. Always present. */
  short: string;
  /** Multi-paragraph body. Empty when the summary suffices. */
  long: string;
}

export const ERRORS: readonly ErrorEntry[] = data;
