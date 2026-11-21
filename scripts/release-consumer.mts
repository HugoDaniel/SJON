import { s, edit } from '@sjon-lang/schema';
import { read, readResult, fields } from '@sjon-lang/read';
import { SjonEncoder, SjonReader } from '@sjon-lang/web';
import { SjonHost } from '@sjon-lang/web/SjonHost';
import * as SjonSchemaBackend from '@sjon-lang/web/SjonSchemaBackend';
import { createNodeFsResolver } from '@sjon-lang/web/createNodeFsResolver';
import { sjonLanguage, sjonTextMateGrammar } from '@sjon-lang/highlight';
import { EditorState } from '@codemirror/state';
import { createHighlighter } from 'shiki';
const [readRoot] = read('(a :k 1)');
if (readRoot?.tag !== 'form' || readRoot.span.start !== 0 || readRoot.span.end !== 8) {
  throw new Error('read tree mismatch');
}
const count = fields(readRoot).get('k');
if (count?.tag !== 'number' || count.value !== 1 || count.integer !== 1n) {
  throw new Error('read fields mismatch');
}
if (readResult('(a :k 1)').diagnostics.length !== 0) {
  throw new Error('read diagnostics mismatch');
}
const Config = s.form('config', { count: s.number() });
Config.manifest();
edit.insertRoot({ $form: 'config', count: 1 });
EditorState.create({ extensions: [sjonLanguage] });
await createHighlighter({ langs: [sjonTextMateGrammar], themes: ['github-dark'] });
void [SjonEncoder, SjonReader, SjonHost, SjonSchemaBackend, createNodeFsResolver];
