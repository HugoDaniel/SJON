// Headless unit tests for the SJON hover bridge. No DOM: the pure parts
// (`isLspHover`, `renderHoverMarkdown`, `hoverAnchor`) are exercised against a
// bare `Text` document and raw markdown strings — the exact subset the server's
// `Handler.zig` hover renderer emits (`**bold**`, `_italic_`, `` `code` ``,
// `[text](url)`, `- ` bullets, `N. ` ordered items, `\n\n` paragraphs). Run with
// `node --test --experimental-strip-types`.

import { test } from 'node:test';
import assert from 'node:assert/strict';

import { Text } from '@codemirror/state';

import { isLspHover, renderHoverMarkdown, hoverAnchor, type LspHover } from './lsp-hover.ts';

// ----- isLspHover ----------------------------------------------------------

test('isLspHover accepts the server hover shape, with and without a range', () => {
  assert.ok(isLspHover({ contents: { kind: 'markdown', value: 'x' } }));
  assert.ok(
    isLspHover({
      contents: { kind: 'markdown', value: 'x' },
      range: { start: { line: 0, character: 0 }, end: { line: 0, character: 1 } },
    }),
  );
});

test('isLspHover rejects non-hover values', () => {
  assert.equal(isLspHover(null), false);
  assert.equal(isLspHover({}), false);
  assert.equal(isLspHover({ contents: 'x' }), false); // contents must be an object
  assert.equal(isLspHover({ contents: { kind: 'markdown' } }), false); // missing value
  assert.equal(isLspHover({ contents: { value: 42 } }), false); // value not a string
});

// ----- renderHoverMarkdown: inline formatting -------------------------------

test('renderHoverMarkdown maps the form-head line to bold/italic/code', () => {
  // Exactly what renderFormSpec emits for a head with a plugin origin.
  const html = renderHoverMarkdown('**(widget)** — _from `test`_');
  assert.equal(html, '<p><strong>(widget)</strong> — <em>from <code>test</code></em></p>');
});

test('renderHoverMarkdown escapes HTML special characters in text runs', () => {
  const html = renderHoverMarkdown('**a < b & c > d**');
  assert.equal(html, '<p><strong>a &lt; b &amp; c &gt; d</strong></p>');
});

test('renderHoverMarkdown leaves code-span contents literal but escaped', () => {
  const html = renderHoverMarkdown('a `x < y` b');
  assert.equal(html, '<p>a <code>x &lt; y</code> b</p>');
});

// ----- renderHoverMarkdown: block structure ---------------------------------

test('renderHoverMarkdown groups `- ` lines into a bullet list', () => {
  const md = '**Keys:**\n- `:size` `number` _(required)_\n- `:color` `string`';
  const html = renderHoverMarkdown(md);
  assert.equal(
    html,
    '<p><strong>Keys:</strong></p>' +
      '<ul>' +
      '<li><code>:size</code> <code>number</code> <em>(required)</em></li>' +
      '<li><code>:color</code> <code>string</code></li>' +
      '</ul>',
  );
});

test('renderHoverMarkdown groups `N. ` lines into an ordered list', () => {
  // renderExprFunc numbers parameters from 0; the ordered list renders them
  // as a plain `<ol>` (the server's 0-based counter is dropped by HTML).
  const md = '**Parameters:**\n0. `number`\n1. `number`';
  const html = renderHoverMarkdown(md);
  assert.equal(
    html,
    '<p><strong>Parameters:</strong></p><ol><li><code>number</code></li><li><code>number</code></li></ol>',
  );
});

test('renderHoverMarkdown separates paragraphs on a blank line', () => {
  const html = renderHoverMarkdown('first para\n\nsecond para');
  assert.equal(html, '<p>first para</p><p>second para</p>');
});

// ----- renderHoverMarkdown: links + safety ----------------------------------

test('renderHoverMarkdown renders a docs link with a safe http(s) url', () => {
  const html = renderHoverMarkdown('see ([docs](https://example.com/a))');
  assert.equal(
    html,
    '<p>see (<a href="https://example.com/a" target="_blank" rel="noreferrer noopener">docs</a>)</p>',
  );
});

test('renderHoverMarkdown neutralises a javascript: url — keeps the text, drops the href', () => {
  const html = renderHoverMarkdown('[click](javascript:alert(1))');
  assert.ok(!html.includes('href'), `should have no href: ${html}`);
  assert.ok(!html.includes('javascript:'), `should not carry the scheme: ${html}`);
  assert.ok(html.includes('click'), `should keep the link text: ${html}`);
});

// ----- hoverAnchor ----------------------------------------------------------

test('hoverAnchor maps an LSP range to CM offsets', () => {
  const doc = Text.of(['(+ 1 2)']);
  const range = { start: { line: 0, character: 1 }, end: { line: 0, character: 2 } };
  assert.deepEqual(hoverAnchor(doc, range, 1), { from: 1, to: 2 });
});

test('hoverAnchor clamps a range that runs past the document end', () => {
  const doc = Text.of(['ab']); // length 2
  const range = { start: { line: 0, character: 1 }, end: { line: 5, character: 9 } };
  assert.deepEqual(hoverAnchor(doc, range, 1), { from: 1, to: 2 });
});

test('hoverAnchor falls back to a zero-width anchor at pos when range is absent', () => {
  const doc = Text.of(['abcdef']);
  const hover: LspHover = { contents: { kind: 'markdown', value: 'x' } };
  assert.deepEqual(hoverAnchor(doc, hover.range, 3), { from: 3, to: 3 });
});
