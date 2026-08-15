import { getSingletonHighlighter, type BundledLanguage, type Highlighter } from 'shiki';
import { sjonTextMateGrammar } from '@sjon/highlight';
import { shikiThemes, shikiTransformers } from './shiki-config.mjs';

let highlighter: Promise<Highlighter> | undefined;

function getHighlighter(): Promise<Highlighter> {
  highlighter ??= getSingletonHighlighter({
    themes: [shikiThemes.light, shikiThemes.dark],
    langs: [sjonTextMateGrammar],
  });
  return highlighter;
}

// Render a SJON code snippet to dual-theme highlighted HTML using the SJON
// TextMate grammar from @sjon/highlight — triple-quoted raw strings and
// leading-; comments now highlight correctly, where the prior Clojure
// approximation broke. Returns a <pre><code>… string ready to inject via
// set:html. Matches the markdown pipeline's Shiki config so static snippets
// and tutorial blocks look identical.
export async function highlight(code: string): Promise<string> {
  const hl = await getHighlighter();
  return hl.codeToHtml(code, {
    // `sjon` is registered above via `langs`, not a Shiki bundled language, so
    // its name isn't in the `BundledLanguage` union — assert what we loaded.
    lang: 'sjon' as BundledLanguage,
    themes: shikiThemes,
    defaultColor: false,
    transformers: shikiTransformers,
  });
}
