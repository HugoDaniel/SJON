/**
 * LSP → CodeMirror completion bridge for the playground.
 *
 * Pure module: maps the SJON LSP's completion items (see `LspCompletionItem`
 * in lsp-types.ts for the exact wire subset the WASM serializer emits) onto
 * `@codemirror/autocomplete` completions, and exposes the CompletionSource
 * that codemirror-setup.ts installs via the LSP compartment.
 *
 * The server never sends `textEdit` — the source computes the replacement
 * range itself: the symbol-ish token before the cursor, except when that
 * token is digit-leading (a bare number awaiting a unit suffix, which the
 * server only offers with the cursor exactly at the number's end — units
 * append, they never replace the number).
 */

import { snippet } from '@codemirror/autocomplete';
import type { Completion, CompletionContext, CompletionResult } from '@codemirror/autocomplete';
import { offsetToLspPos, requestCompletion } from './lsp-integration';
import type { LspCompletionItem } from './lsp-types';

/**
 * Convert an LSP snippet body to a CodeMirror snippet template.
 *
 * The server emits (Handler.zig `appendSnippetEscaped` and friends):
 * `${n:default}`, `${n}`, bare `$n`, final stops `$0`/`${0}`, boolean
 * choices `${n|true,false|}`, and backslash escapes for `$`, `}`, `\`.
 * CodeMirror's `snippet()` understands only `${n}`/`${n:default}`/`${}`
 * (empty = visited last) with `\{`/`\}` brace escapes, so:
 *
 * - bare `$n`  → `${n}`
 * - `$0`/`${0}` → `${}` (CM's unnumbered field is visited last — LSP
 *   final-tabstop semantics)
 * - `${n|a,b|}` → `${n:a}` (CM has no choice UI; first choice as default)
 * - LSP `\$`/`\\` unescape to the literal; literal braces re-escape as
 *   `\{`/`\}` so a `$`/`#` before them can't open a field
 *
 * A literal `}` inside a numbered default is unrepresentable in CM (its
 * parser stops a default at the first `}` regardless of backslash); SJON
 * defaults are symbols/numbers, which can't contain braces, so the
 * converter just drops the backslash in that unreachable case.
 */
export function lspSnippetToCmTemplate(source: string): string {
  let out = '';
  let i = 0;
  while (i < source.length) {
    const c = source[i];
    if (c === '\\' && i + 1 < source.length) {
      const next = source[i + 1];
      if (next === '$' || next === '\\') {
        out += next;
        i += 2;
        continue;
      }
      if (next === '}') {
        out += '\\}';
        i += 2;
        continue;
      }
      out += c;
      i += 1;
      continue;
    }
    if (c === '$') {
      const rest = source.slice(i + 1);
      const bare = /^(\d+)/.exec(rest);
      if (bare?.[1] !== undefined && rest[bare[1].length] !== '{') {
        // Bare `$n` tab stop (also covers `$0`).
        out += bare[1] === '0' ? '${}' : `\${${bare[1]}}`;
        i += 1 + bare[1].length;
        continue;
      }
      const braced = /^\{(\d+)(?:(:|\|)((?:\\[$}\\]|[^}])*))?\}/.exec(rest);
      if (braced?.[1] !== undefined) {
        const n = braced[1];
        const sep = braced[2];
        const body = braced[3] ?? '';
        if (n === '0') {
          out += '${}';
        } else if (sep === undefined) {
          out += `\${${n}}`;
        } else {
          // `:default` or `|a,b,…|` — unescape the LSP escapes, take the
          // first choice for `|`, re-escape braces for CM.
          let value = sep === '|' ? (body.replace(/\|$/, '').split(',')[0] ?? '') : body;
          value = value.replace(/\\([$}\\])/g, '$1').replace(/\{/g, '\\{');
          out += `\${${n}:${value}}`;
        }
        i += 1 + braced[0].length;
        continue;
      }
      out += '$';
      i += 1;
      continue;
    }
    if (c === '{' || c === '}') {
      out += `\\${c}`;
      i += 1;
      continue;
    }
    out += c;
    i += 1;
  }
  return out;
}

/** LSP CompletionItemKind → CodeMirror completion `type` (icon). Only the
 *  four kinds the server actually emits. */
const KIND_TO_TYPE: Readonly<Record<number, string>> = {
  3: 'function', // expr functions
  4: 'class', // form heads (LSP Constructor)
  5: 'property', // keyword keys (LSP Field)
  20: 'enum', // enum members, units, cross-refs
};

function toCmCompletion(item: LspCompletionItem, boost: number): Completion {
  // CM fuzzy-matches against `label`, so the LSP `filterText` takes that
  // slot and the real label moves to `displayLabel`.
  const completion: Completion = {
    label: item.filterText ?? item.label,
    boost,
  };
  if (item.filterText !== undefined && item.filterText !== item.label) {
    completion.displayLabel = item.label;
  }
  const type = item.kind !== undefined ? KIND_TO_TYPE[item.kind] : undefined;
  if (type !== undefined) completion.type = type;

  // CM has no strikethrough affordance — surface deprecation in the detail.
  const deprecated = item.tags !== undefined && item.tags.includes(1);
  const detail =
    item.detail !== undefined && item.detail.length > 0
      ? deprecated
        ? `${item.detail} (deprecated)`
        : item.detail
      : deprecated
        ? '(deprecated)'
        : undefined;
  if (detail !== undefined) completion.detail = detail;
  if (item.documentation !== undefined && item.documentation.length > 0) {
    // The WASM serializer emits plain strings (never MarkupContent), which
    // CM renders as text in the info panel.
    completion.info = item.documentation;
  }
  if (item.insertText !== undefined) {
    completion.apply =
      item.insertTextFormat === 2
        ? snippet(lspSnippetToCmTemplate(item.insertText))
        : item.insertText;
  }
  // `commitCharacters` are dropped — CM completions have no per-item
  // commit-character support; Enter/Tab accept covers the flow.
  return completion;
}

/**
 * Map a server result to CM completions, preserving the server's intended
 * order: CM re-ranks by fuzzy score then `boost` then label, so each item's
 * `sortText` rank becomes its boost and survives among equal-score matches.
 */
export function toCmCompletions(items: readonly LspCompletionItem[]): Completion[] {
  const order = items.map((item, index) => ({ index, key: item.sortText ?? item.label }));
  order.sort((a, b) => (a.key < b.key ? -1 : a.key > b.key ? 1 : a.index - b.index));
  const boosts: number[] = new Array(items.length).fill(0);
  order.forEach((entry, rank) => {
    boosts[entry.index] = Math.max(-99, 99 - rank);
  });
  return items.map((item, index) => toCmCompletion(item, boosts[index] ?? 0));
}

/** SJON symbol-ish charset — what counts as "the token being completed". */
const TOKEN_BEFORE = /[A-Za-z0-9_$!?*+\-./<>=]+$/;
const VALID_FOR = /^[A-Za-z0-9_$!?*+\-./<>=]*$/;

/** The server's advertised completion trigger characters. */
const TRIGGER_CHARS: ReadonlySet<string> = new Set(['(', ':', '[']);

/**
 * CompletionSource backed by the SJON LSP's `textDocument/completion`.
 *
 * Fires on explicit request (Ctrl-Space), while typing inside a symbol-ish
 * token, or right after a trigger character. `validFor` lets CM re-filter
 * client-side while the user keeps typing within the token instead of a
 * WASM round-trip per keystroke (sound because matching happens against
 * `label` = LSP `filterText`).
 */
export async function sjonCompletionSource(
  context: CompletionContext,
): Promise<CompletionResult | null> {
  const token = context.matchBefore(TOKEN_BEFORE);
  if (!context.explicit && token === null) {
    const before =
      context.pos > 0 ? context.state.doc.sliceString(context.pos - 1, context.pos) : '';
    if (!TRIGGER_CHARS.has(before)) return null;
  }

  const items = await requestCompletion(
    context.state.doc.toString(),
    offsetToLspPos(context.state.doc, context.pos),
  );
  if (context.aborted || items === null || items.length === 0) return null;

  // Digit-leading token = bare number awaiting a unit suffix → append at
  // the cursor; otherwise replace the token. (SJON symbols never start
  // with a digit, so the split is unambiguous.)
  const from = token !== null && !/^[0-9]/.test(token.text) ? token.from : context.pos;
  return { from, options: toCmCompletions(items), validFor: VALID_FOR };
}
