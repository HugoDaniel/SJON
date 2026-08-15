/**
 * LSP → CodeMirror hover bridge for the playground.
 *
 * Framework-only, mirroring lsp-folding.ts: this module never touches the LSP
 * transport. `lsp-integration.ts` owns the round-trip (`requestHover`); boot.ts
 * injects a `HoverSource` closure and this module renders the result. Keeping
 * the transport out means the pure parts below are unit-testable against a bare
 * `Text` document (see lsp-hover.test.ts).
 *
 * The server (`textDocument/hover`) returns `{contents:{kind:"markdown",value},
 * range}`. The markdown is a small, fixed subset produced by `Handler.zig`'s
 * `renderFormSpec`/`renderExprFunc`/`renderKeySpec`: `**bold**`, `_italic_`,
 * `` `code` ``, `[text](url)` docs links, `- ` bullets, `N. ` ordered params,
 * and `\n\n` paragraph breaks. `renderHoverMarkdown` is a line-oriented
 * mini-renderer for exactly that subset — it never runs a general markdown
 * parser, and it escapes every text run so schema-authored content can't inject
 * markup (docs links are additionally scheme-filtered to http(s)/relative).
 */

import { hoverTooltip } from '@codemirror/view';
import type { Extension, Text } from '@codemirror/state';
// Explicit `.ts` extension: this module is loaded directly by
// `node --test --experimental-strip-types`, which resolves specifiers as
// written rather than through Vite. A *type* import erases before that
// matters, but a runtime one must name the file. Don't "tidy" it away —
// `pnpm test` fails with ERR_MODULE_NOT_FOUND.
import { rangeToOffsets } from './lsp-types.ts';
import type { LspRange } from './lsp-types';

/** The `textDocument/hover` result subset the WASM serializer emits. */
export interface LspHover {
  contents: { kind?: string; value: string };
  range?: LspRange;
}

/** Fetches a hover for `pos` in `doc`, or null. Injected by boot.ts so this
 *  module stays free of the LSP transport (the completionSource pattern). */
export type HoverSource = (doc: Text, pos: number) => Promise<LspHover | null>;

/** Structural guard for a server hover: a `contents` object carrying a string
 *  `value`. `range` is optional (the server always sends it, but hover is valid
 *  without one). */
export function isLspHover(x: unknown): x is LspHover {
  if (typeof x !== 'object' || x === null || !('contents' in x)) return false;
  const contents = (x as { contents: unknown }).contents;
  return (
    typeof contents === 'object' &&
    contents !== null &&
    typeof (contents as { value: unknown }).value === 'string'
  );
}

// ----- markdown → HTML (fixed subset) --------------------------------------

function escapeHtml(s: string): string {
  return s.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;');
}

function escapeAttr(s: string): string {
  return escapeHtml(s).replace(/"/g, '&quot;');
}

/** Keep only hrefs we can vouch for: absolute http(s), or relative/anchor
 *  targets. Anything carrying an untrusted scheme (`javascript:`, `data:`, …)
 *  is rejected so the caller drops the href and keeps just the link text. */
function safeUrl(url: string): string | null {
  if (/^https?:\/\//i.test(url)) return url;
  if (/^[./#]/.test(url)) return url; // relative path or in-page anchor
  if (/^[a-z][a-z0-9+.-]*:/i.test(url)) return null; // some other scheme — distrust
  return url;
}

/**
 * Render one line's inline markup. Precedence: code spans (literal), then
 * `[text](url)` links, then `**bold**`, then `_italic_`; anything unmatched is
 * escaped plain text. Bold/italic recurse on their (strictly smaller) inner
 * span so `_from `x`_` nests correctly. An unterminated marker is emitted as a
 * literal so a stray `` ` ``/`*`/`_` in schema prose can't run away.
 */
export function renderInline(text: string): string {
  let out = '';
  let plain = '';
  let i = 0;
  const flush = (): void => {
    if (plain.length > 0) {
      out += escapeHtml(plain);
      plain = '';
    }
  };
  while (i < text.length) {
    const c = text[i];
    if (c === '`') {
      const end = text.indexOf('`', i + 1);
      if (end !== -1) {
        flush();
        out += `<code>${escapeHtml(text.slice(i + 1, end))}</code>`;
        i = end + 1;
        continue;
      }
    } else if (c === '[') {
      const m = /^\[([^\]]*)\]\(([^)]*)\)/.exec(text.slice(i));
      if (m) {
        flush();
        const url = safeUrl(m[2] ?? '');
        const inner = renderInline(m[1] ?? '');
        out +=
          url !== null
            ? `<a href="${escapeAttr(url)}" target="_blank" rel="noreferrer noopener">${inner}</a>`
            : inner;
        i += m[0].length;
        continue;
      }
    } else if (c === '*' && text[i + 1] === '*') {
      const end = text.indexOf('**', i + 2);
      if (end !== -1) {
        flush();
        out += `<strong>${renderInline(text.slice(i + 2, end))}</strong>`;
        i = end + 2;
        continue;
      }
    } else if (c === '_' && (plain.length === 0 || /\s|\(/.test(plain[plain.length - 1] ?? ''))) {
      // Only open emphasis at a word boundary (line start or after whitespace/
      // `(`) — matches every `_…_` the server emits and leaves a stray
      // underscore inside prose (`snake_case`) untouched.
      const end = text.indexOf('_', i + 1);
      if (end !== -1) {
        flush();
        out += `<em>${renderInline(text.slice(i + 1, end))}</em>`;
        i = end + 1;
        continue;
      }
    }
    plain += c;
    i += 1;
  }
  flush();
  return out;
}

/**
 * Render the server's hover markdown to a safe HTML string (no DOM — the CM
 * extension sets it as `innerHTML`). Line-oriented: consecutive `- ` lines
 * become one `<ul>`, consecutive `N. ` lines one `<ol>`, blank lines split
 * paragraphs, and other runs of lines join with `<br>` inside a `<p>`.
 */
export function renderHoverMarkdown(md: string): string {
  const lines = md.split('\n');
  const out: string[] = [];
  let para: string[] = [];
  const flushPara = (): void => {
    if (para.length > 0) {
      out.push(`<p>${para.map(renderInline).join('<br>')}</p>`);
      para = [];
    }
  };

  let i = 0;
  while (i < lines.length) {
    const line = lines[i] ?? '';
    if (line === '') {
      flushPara();
      i += 1;
    } else if (line.startsWith('- ')) {
      flushPara();
      const items: string[] = [];
      while (i < lines.length && (lines[i] ?? '').startsWith('- ')) {
        items.push(`<li>${renderInline((lines[i] ?? '').slice(2))}</li>`);
        i += 1;
      }
      out.push(`<ul>${items.join('')}</ul>`);
    } else if (/^\d+\. /.test(line)) {
      flushPara();
      const items: string[] = [];
      while (i < lines.length && /^\d+\. /.test(lines[i] ?? '')) {
        items.push(`<li>${renderInline((lines[i] ?? '').replace(/^\d+\. /, ''))}</li>`);
        i += 1;
      }
      out.push(`<ol>${items.join('')}</ol>`);
    } else {
      para.push(line);
      i += 1;
    }
  }
  flushPara();
  return out.join('');
}

// ----- range mapping -------------------------------------------------------

/**
 * Turn the server's hover range into the `{from, to}` the tooltip anchors over,
 * clamped to `doc`. When the server sent no range, fall back to a zero-width
 * anchor at the queried offset so the tooltip still appears under the cursor.
 */
export function hoverAnchor(
  doc: Text,
  range: LspRange | undefined,
  pos: number,
): { from: number; to: number } {
  if (!range) {
    const clamped = Math.max(0, Math.min(pos, doc.length));
    return { from: clamped, to: clamped };
  }
  return rangeToOffsets(doc, range);
}

// ----- CodeMirror extension -------------------------------------------------

/**
 * Hover tooltips backed by `source`. Dismissed on any doc change
 * (`hideOnChange`) so a stale card never lingers over edited text. The tooltip
 * card is a single `.cm-sjon-hover` div holding the rendered markdown; chrome
 * comes from the `.cm-tooltip.cm-tooltip-hover` rule in codemirror-setup.ts.
 */
export function sjonHoverExtension(source: HoverSource): Extension {
  return hoverTooltip(
    async (view, pos) => {
      const hover = await source(view.state.doc, pos);
      if (hover === null || hover.contents.value.length === 0) return null;
      const { from, to } = hoverAnchor(view.state.doc, hover.range, pos);
      const html = renderHoverMarkdown(hover.contents.value);
      return {
        pos: from,
        end: to,
        above: true,
        create: () => {
          const dom = document.createElement('div');
          dom.className = 'cm-sjon-hover';
          dom.innerHTML = html;
          return { dom };
        },
      };
    },
    { hideOnChange: true },
  );
}
