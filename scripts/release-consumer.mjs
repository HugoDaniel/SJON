import assert from 'node:assert/strict';
import { s, edit } from '@sjon-lang/schema';
import { SjonEncoder, SjonReader } from '@sjon-lang/web';
import { SjonHost } from '@sjon-lang/web/SjonHost';
import * as backend from '@sjon-lang/web/SjonSchemaBackend';
import * as resolver from '@sjon-lang/web/createNodeFsResolver';
import { sjonLanguage, sjonTextMateGrammar } from '@sjon-lang/highlight';
import { EditorState } from '@codemirror/state';
import { createHighlighter } from 'shiki';
const wasm = process.env['SJON_WASM_DIR'];
assert.ok(wasm);
const encoder = await SjonEncoder.load(`${wasm}/sjon.wasm`);
const reader = await SjonReader.load(`${wasm}/sjon-binary.wasm`);
assert.equal(reader.evalExprBinary(encoder.toBinary('(+ 1 2)')), 3);
assert.equal(reader.validateBinary(encoder.toBinary('(+ 1 2)')).diagnostics.length, 0);
assert.match(encoder.applyEdit('(a :x 1)', edit.setKey([], 'x', 2)), /:x 2/);
assert.equal(typeof SjonHost.load, 'function');
assert.ok(Object.keys(backend).length && Object.keys(resolver).length);
assert.ok(s.form('config', { count: s.number() }).manifest().includes('config'));
assert.equal(EditorState.create({ extensions: [sjonLanguage] }).doc.length, 0);
const highlighter = await createHighlighter({
  langs: [sjonTextMateGrammar],
  themes: ['github-dark'],
});
assert.ok(
  highlighter.codeToHtml('(a :x 2)', { lang: 'sjon', theme: 'github-dark' }).includes('shiki'),
);
highlighter.dispose();
console.log(`packed smoke passed on ${process.version}`);
