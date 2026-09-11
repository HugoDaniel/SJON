// @sjon-lang/highlight — exhaustive grammar tests across BOTH engines.
//
// Layers, narrowest → broadest:
//   1. `sjonToken` (CodeMirror) — the ported-seed regression net, driven over a
//      StringStream exactly as CM6's driver does (token-level (text,style) pairs).
//   2. TextMate scope surface (Shiki) — the *named* scopes each construct emits,
//      so themes have stable targets (renaming one silently breaks coloring).
//   3. CM↔TM per-CHARACTER parity — both engines reduced to a coarse class per
//      char; over a curated "should agree" corpus they must match exactly. This
//      is the long-tail net: it catches drift between the playground (CM) and the
//      static-docs (TM/Shiki) renderers that token-level checks miss.
//   4. Documented divergences — the two places the engines legitimately differ,
//      pinned so a regression there is a conscious choice, not an accident.
//
// Fidelity was hand-verified against src/Lexer.zig and docs/LANGUAGE.md §2.
// SJON has constructs neither highlighter resolves to a single token — `date`
// (`YYYY-MM-DD`), `time` (`HH:MM:SS`), trailing-dot `2.` — which the lexer lexes
// whole but a highlighter splits. Those are deliberate graceful degradations:
// the per-char COLOR stays sane (all-numeric, etc.), so they live in the parity
// corpus, asserted as the (degraded but agreeing) reality they are.

import { describe, it } from 'node:test';
import { strict as assert } from 'node:assert';
import { readFileSync } from 'node:fs';
import { resolve, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
import { StringStream } from '@codemirror/language';
import {
  createHighlighter,
  type BundledLanguage,
  type Highlighter,
  type LanguageRegistration,
} from 'shiki';
import { sjonToken, type SjonStreamState } from '../src/codemirror.ts';

const here = dirname(fileURLToPath(import.meta.url));

// ===========================================================================
// Shared coarse-class harness
// ===========================================================================
//
// Both engines emit engine-specific token names; reduce each to one of eight
// coarse classes and render a line as a one-letter-per-char string so a whole
// document's coloring reads at a glance and diffs precisely.

type Coarse = 'comment' | 'string' | 'number' | 'atom' | 'key' | 'head' | 'punct' | 'plain';
const LETTER: Record<Coarse, string> = {
  comment: 'c',
  string: 's',
  number: 'n',
  atom: 'a',
  key: 'k',
  head: 'h',
  punct: 'p',
  plain: '.',
};

// ---- CodeMirror side -------------------------------------------------------

function cmCoarse(style: string | null): Coarse {
  switch (style) {
    case 'lineComment':
    case 'blockComment':
      return 'comment';
    case 'string':
      return 'string';
    case 'number':
      return 'number';
    case 'atom':
      return 'atom';
    case 'propertyName':
      return 'key';
    case 'keyword':
      return 'head';
    case 'punctuation':
      return 'punct';
    default:
      return 'plain';
  }
}

const freshState = (): SjonStreamState => ({ inRaw: false, inBlock: false, afterParen: false });

interface CmSpan {
  from: number;
  to: number;
  style: string | null;
}

// Drive the StreamLanguage token fn over one line exactly as CM6's driver does:
// reset `start` to `pos` before each call so `stream.current()` yields just the
// current token; `state` carries across lines so raw-string / block-comment
// spans resume.
function cmLineSpans(line: string, state: SjonStreamState): CmSpan[] {
  const stream = new StringStream(line, 4, 4);
  const spans: CmSpan[] = [];
  let guard = 0;
  while (!stream.eol()) {
    if (++guard > 10000) throw new Error('tokenizer did not terminate');
    const from = stream.pos;
    stream.start = from;
    const style = sjonToken(stream, state);
    if (stream.pos === from) stream.next(); // never stall
    spans.push({ from, to: stream.pos, style });
  }
  return spans;
}

interface StyledToken {
  text: string;
  style: string | null;
}

function tokenizeLine(line: string, state: SjonStreamState): StyledToken[] {
  return cmLineSpans(line, state).map((s) => ({ text: line.slice(s.from, s.to), style: s.style }));
}

const tok = (line: string): StyledToken[] => tokenizeLine(line, freshState());

// (text,style) pairs for styled tokens only (drops whitespace nulls).
function styled(tokens: StyledToken[]): Array<[string, string]> {
  const out: Array<[string, string]> = [];
  for (const t of tokens) if (t.style !== null) out.push([t.text, t.style]);
  return out;
}

// Per-line coarse-class letter strings for a whole document (shared state).
function cmClasses(code: string): string[] {
  const state = freshState();
  return code.split('\n').map((line) => {
    const arr: Coarse[] = new Array(line.length).fill('plain');
    for (const s of cmLineSpans(line, state)) {
      const c = cmCoarse(s.style);
      for (let i = s.from; i < s.to; i++) arr[i] = c;
    }
    return arr.map((c) => LETTER[c]).join('');
  });
}

// ---- TextMate / Shiki side -------------------------------------------------

const grammarPath = resolve(here, '../src/sjon.tmLanguage.json');
const loadGrammar = (): LanguageRegistration =>
  JSON.parse(readFileSync(grammarPath, 'utf8')) as LanguageRegistration;

// One highlighter, lazily built and memoized — createHighlighter is the only
// async/expensive step.
let highlighterPromise: Promise<Highlighter> | undefined;
const getHighlighter = (): Promise<Highlighter> => {
  highlighterPromise ??= createHighlighter({ themes: ['min-light'], langs: [loadGrammar()] });
  return highlighterPromise;
};

function tmCoarse(scopes: string[]): Coarse {
  // innermost-wins: the most specific `.sjon` scope on this span
  const s = [...scopes].reverse().find((x) => x.endsWith('.sjon')) ?? '';
  if (s.startsWith('comment')) return 'comment';
  if (s.startsWith('string')) return 'string';
  if (s.startsWith('constant.character')) return 'string'; // escapes are string-family
  if (s.startsWith('constant.numeric')) return 'number';
  if (s.startsWith('constant.language')) return 'atom';
  if (s.startsWith('entity.name.tag')) return 'key';
  if (s.startsWith('entity.name.function')) return 'head';
  if (s.startsWith('punctuation')) return 'punct';
  return 'plain';
}

// Per-line coarse-class letter strings. Walk explanation SUB-SPANS, not tokens:
// Shiki merges adjacent same-color tokens, so a token's scope list flattens
// distinct spans and lies about per-char class. (Corpus is ASCII, so code-point
// iteration aligns with the UTF-16 column array.)
async function tmClasses(code: string): Promise<string[]> {
  const hl = await getHighlighter();
  const { tokens } = hl.codeToTokens(code, {
    lang: 'sjon' as BundledLanguage,
    theme: 'min-light',
    includeExplanation: true,
  });
  return code.split('\n').map((line, li) => {
    const arr: Coarse[] = new Array(line.length).fill('plain');
    let col = 0;
    for (const t of tokens[li] ?? []) {
      const spans = t.explanation;
      if (spans) {
        for (const sp of spans) {
          const c = tmCoarse(sp.scopes.map((s) => s.scopeName));
          for (let k = 0; k < sp.content.length; k++, col++) if (col < arr.length) arr[col] = c;
        }
      } else {
        for (let k = 0; k < t.content.length; k++, col++) if (col < arr.length) arr[col] = 'plain';
      }
    }
    return arr.map((c) => LETTER[c]).join('');
  });
}

// All `.sjon` scope names emitted anywhere in `code` — the named-scope surface.
async function tmScopes(code: string): Promise<Set<string>> {
  const hl = await getHighlighter();
  const { tokens } = hl.codeToTokens(code, {
    lang: 'sjon' as BundledLanguage,
    theme: 'min-light',
    includeExplanation: true,
  });
  const out = new Set<string>();
  for (const line of tokens)
    for (const t of line)
      for (const e of t.explanation ?? [])
        for (const sc of e.scopes) if (sc.scopeName.endsWith('.sjon')) out.add(sc.scopeName);
  return out;
}

// ===========================================================================
// 1. CodeMirror tokenizer — ported-seed regression + long tail
// ===========================================================================

describe('sjonToken (CodeMirror) — ported seed', () => {
  it('styles a leading-; line comment', () => {
    assert.deepEqual(styled(tok('; a comment')), [['; a comment', 'lineComment']]);
  });

  it('styles a form head as keyword and its :keys as propertyName', () => {
    assert.deepEqual(styled(tok('(buffer :name b :size 32)')), [
      ['(', 'punctuation'],
      ['buffer', 'keyword'],
      [':name', 'propertyName'],
      [':size', 'propertyName'],
      ['32', 'number'],
      [')', 'punctuation'],
    ]);
  });

  it('leaves a non-head symbol unstyled (plain text)', () => {
    const t = tok('(x :name b)');
    assert.equal(t.find((e) => e.text === 'b')?.style, null);
    assert.equal(t.find((e) => e.text === 'x')?.style, 'keyword');
  });

  it('styles literals true/false/nil as atoms', () => {
    assert.deepEqual(styled(tok(':feedback true')), [
      [':feedback', 'propertyName'],
      ['true', 'atom'],
    ]);
    assert.equal(tok('nil').find((e) => e.text === 'nil')?.style, 'atom');
  });

  it('styles numbers: integer, signed-decimal, exponent', () => {
    assert.equal(tok('3').find((e) => e.text === '3')?.style, 'number');
    assert.equal(tok('-3.5').find((e) => e.text === '-3.5')?.style, 'number');
    assert.equal(tok('1e3').find((e) => e.text === '1e3')?.style, 'number');
  });

  it('styles vector brackets as punctuation, elements unstyled', () => {
    assert.deepEqual(styled(tok('[vertex storage]')), [
      ['[', 'punctuation'],
      [']', 'punctuation'],
    ]);
  });

  it('styles expr-function heads as keywords', () => {
    assert.equal(tok('(* NUM 4 4)').find((e) => e.text === '*')?.style, 'keyword');
    const inner = tok('(ceil (/ NUM 64))');
    assert.equal(inner.find((e) => e.text === 'ceil')?.style, 'keyword');
    assert.equal(inner.find((e) => e.text === '/')?.style, 'keyword');
  });

  it('styles a single-line normal string', () => {
    assert.equal(tok('"hi"').find((e) => e.text === '"hi"')?.style, 'string');
  });

  it('styles a single-line raw string and does NOT enter inRaw', () => {
    const state = freshState();
    const t = tokenizeLine(':code """x"""', state);
    assert.equal(state.inRaw, false);
    assert.ok(styled(t).some(([text, style]) => text === '"""x"""' && style === 'string'));
  });

  it('carries a multi-line raw string across lines, then closes', () => {
    const state = freshState();
    const l1 = tokenizeLine('  (pass :name main :code """', state);
    assert.equal(state.inRaw, true);
    assert.equal(l1[l1.length - 1]?.style, 'string');
    const l2 = tokenizeLine('    return vec4f(1.0);', state);
    assert.equal(state.inRaw, true);
    assert.deepEqual(l2, [{ text: '    return vec4f(1.0);', style: 'string' }]);
    const l3 = tokenizeLine('  """))', state);
    assert.equal(state.inRaw, false);
    assert.equal(l3[0]?.style, 'string');
    assert.equal(l3[l3.length - 1]?.style, 'punctuation');
  });

  it('a quote inside a raw-string body does not prematurely close it', () => {
    const state = freshState();
    tokenizeLine(':code """', state);
    const body = tokenizeLine('let s = "x";', state);
    assert.equal(state.inRaw, true);
    assert.deepEqual(body, [{ text: 'let s = "x";', style: 'string' }]);
  });
});

describe('sjonToken (CodeMirror) — long tail', () => {
  // --- comments ---
  it('treats ;; and ;no-space as line comments', () => {
    assert.equal(cmClasses(';; section')[0], 'cccccccccc');
    assert.equal(cmClasses(';nospace')[0], 'cccccccc');
  });
  it('styles a trailing comment after code', () => {
    assert.equal(cmClasses('(foo) ; tail')[0], 'phhhp.cccccc');
  });
  it('styles a one-line inline #| |# block comment', () => {
    assert.equal(cmClasses('(foo #| in |# bar)')[0], 'phhh.cccccccc....p');
  });
  it('carries a #| |# block comment across lines, then closes', () => {
    assert.deepEqual(cmClasses('#| line one\nline two |#'), ['ccccccccccc', 'ccccccccccc']);
  });
  it('closes a block comment at the FIRST |# — no nesting (LANGUAGE.md §2.2)', () => {
    // `#| a #| b |#` ends at the first `|#`; ` c |#` after it is code.
    assert.equal(cmClasses('#| a #| b |# c |#')[0], 'cccccccccccc.....');
  });
  it('does not see :keys/;/" inside a block comment as their own tokens', () => {
    assert.equal(cmClasses('#| ; "x" :k |#')[0], 'cccccccccccccc');
  });

  // --- strings ---
  it('styles empty, escaped, and key/;-bearing strings as one string', () => {
    assert.equal(cmClasses('""')[0], 'ss');
    assert.equal(cmClasses('"a\\"b"')[0], 'ssssss'); // escaped quote does not close early
    assert.equal(cmClasses('":foo ; not"')[0], 'ssssssssssss'); // :foo / ; are content
  });
  it('tolerates an unterminated string to end of line', () => {
    assert.equal(cmClasses('"abc')[0], 'ssss');
  });

  // --- raw strings ---
  it('handles empty and greedy-close raw strings on one line', () => {
    assert.equal(cmClasses('""""""')[0], 'ssssss'); // """ open + """ close, empty body
    assert.equal(cmClasses('""""abc"""')[0], 'ssssssssss'); // body is `"abc` (greedy close)
  });
  it('tolerates an unterminated raw string across the rest of the document', () => {
    assert.deepEqual(cmClasses(':code """\nstill open'), ['kkkkk.sss', 'ssssssssss']);
  });

  // --- numbers + units (LANGUAGE.md §2.6) ---
  it('styles unit suffixes and underscore grouping as one number', () => {
    assert.equal(cmClasses('90deg')[0], 'nnnnn');
    assert.equal(cmClasses('50%')[0], 'nnn');
    assert.equal(cmClasses('1em')[0], 'nnn'); // e-not-followed-by-digit ⇒ unit, not exponent
    assert.equal(cmClasses('1.5e+2hz')[0], 'nnnnnnnn');
    assert.equal(cmClasses('1_000_000')[0], 'nnnnnnnnn');
  });
  it('styles a hex integer as one number, digit-containing tail included', () => {
    assert.equal(cmClasses('0xFF')[0], 'nnnn');
    assert.equal(cmClasses('0Xff')[0], 'nnnn');
    assert.equal(cmClasses('0xFFFF_FFFF')[0], 'nnnnnnnnnnn');
    assert.equal(cmClasses('-0x10')[0], 'nnnnn');
    // The reason the hex alternative has to come first in the regex: under
    // the decimal alternative this is `0x` (number, unit `x`) then `1F`
    // (number, unit `F`) — two numbers where the lexer now sees one.
    assert.equal(cmClasses('0x1F')[0], 'nnnn');
  });
  it('splits `0xFFms` the way the lexer does (hex integer, then a symbol)', () => {
    // Hex terminates at the first non-hex byte and takes no unit, so `ms`
    // is a bare symbol — plain, per the grammar's unscoped-symbol rule.
    assert.equal(cmClasses('0xFFms')[0], 'nnnn..');
  });
  it('DEGRADES a bare `0x` prefix to a unit number (lexer: an invalid token)', () => {
    // Neither grammar models error tokens — `1e+` colours numeric too. The
    // hex alternative requires at least one digit, so this falls through to
    // the decimal alternative and reads as `0` with the unit `x`.
    assert.equal(cmClasses('0x')[0], 'nn');
  });
  it('styles a hyphenated unit as one number', () => {
    // `2d-array` is the spelling `GPUTextureViewDimension` needs, and the
    // reason the unit regex grew a `(?:-[a-zA-Z]+)*` tail.
    assert.equal(cmClasses('2d-array')[0], 'nnnnnnnn');
    assert.equal(cmClasses('5ms-per-frame')[0], 'nnnnnnnnnnnnn');
  });
  it('ends the unit at a hyphen not followed by a letter', () => {
    // `1em-2` is `1em` then `-2` — two numbers, no gap. The narrowness of
    // the lexer's rule is visible here: a permissive hyphen would colour
    // the whole thing as one token with the unit `em-2`.
    assert.equal(cmClasses('1em-2')[0], 'nnnnn');
    assert.equal(cmClasses('2d-2')[0], 'nnnn');
    // A trailing hyphen becomes a bare symbol, which is unstyled.
    assert.equal(cmClasses('2d-')[0], 'nn.');
  });
  it('splits adjacent unit numbers like the lexer (90deg5px ⇒ two numbers)', () => {
    // Per §2.6: `90deg5px` lexes as `90deg` then `5px`; both colour numeric.
    assert.equal(cmClasses('90deg5px')[0], 'nnnnnnnn');
  });
  it('treats a lone "-" as a head/symbol, not a number', () => {
    assert.equal(cmClasses('(- 1 2)')[0], 'ph.n.np');
  });

  // --- keywords / symbols ---
  it('styles keywords with operator, dot, and slash bodies', () => {
    assert.equal(cmClasses(':p+s')[0], 'kkkk');
    assert.equal(cmClasses(':a.b')[0], 'kkkk');
    assert.equal(cmClasses(':ns/k')[0], 'kkkkk');
  });
  it('leaves a lone colon unstyled', () => {
    assert.equal(cmClasses(':')[0], '.');
  });

  // --- forms ---
  it('handles empty, nested, doubled, and space-after-paren forms', () => {
    assert.equal(cmClasses('()')[0], 'pp');
    assert.equal(cmClasses('(a (b c))')[0], 'ph.ph..pp');
    assert.equal(cmClasses('((a))')[0], 'pphpp'); // inner symbol is the head
    assert.equal(cmClasses('( foo )')[0], 'p.hhh.p'); // whitespace before head is fine
  });
  it('styles a :keyword head as a key, not a function head', () => {
    assert.equal(cmClasses('(:foo)')[0], 'pkkkkp');
  });

  // --- deliberate graceful degradations (single token in the lexer; cf. header) ---
  it('DEGRADES a date to an all-numeric run (lexer: one `date` token)', () => {
    assert.equal(cmClasses('2026-06-09')[0], 'nnnnnnnnnn');
  });
  it('DEGRADES a time to number + key (lexer: one `time` token)', () => {
    assert.equal(cmClasses('12:30:00')[0], 'nnkkkkkk');
  });
  it('DEGRADES a trailing-dot number `2.` to number + plain (lexer: one number)', () => {
    assert.equal(cmClasses('2.')[0], 'n.');
  });
});

// ===========================================================================
// 2. TextMate grammar — named-scope surface (Shiki)
// ===========================================================================

describe('TextMate grammar (Shiki) — registration & named scopes', () => {
  it('registers `sjon` as a loaded language (no plaintext fallback)', async () => {
    const hl = await getHighlighter();
    assert.ok(hl.getLoadedLanguages().includes('sjon'));
  });

  it('emits the stable named scope for every construct themes target', async () => {
    // One document exercising every scope at once.
    const doc = [
      '; line',
      '#| block |#',
      '(form :key "str \\n esc" :raw """raw""" 42 90deg true [vec])',
    ].join('\n');
    const scopes = await tmScopes(doc);
    for (const want of [
      'comment.line.semicolon.sjon',
      'comment.block.sjon',
      'string.quoted.double.sjon',
      'constant.character.escape.sjon',
      'string.quoted.triple.sjon',
      'entity.name.tag.sjon',
      'entity.name.function.sjon',
      'constant.numeric.sjon',
      'constant.language.sjon',
      'punctuation.section.parens.begin.sjon',
      'punctuation.section.parens.end.sjon',
      'punctuation.section.brackets.sjon',
    ]) {
      assert.ok(scopes.has(want), `grammar emits ${want}`);
    }
  });

  it('scopes a """…""" body (with an inner quote) as one raw string across lines', async () => {
    // The construct Clojure breaks on: opening """ + a body line with a lone "
    // + the closing """ — all string, not "empty string then code".
    const cls = await tmClasses('"""\nlet x = "y";\n"""');
    assert.deepEqual(cls, ['sss', 'ssssssssssss', 'sss']);
  });
});

// ===========================================================================
// 3. CM ↔ TextMate per-character parity
// ===========================================================================
//
// The playground (CM) and the static-docs (TM/Shiki) must colour the same
// bytes the same way. Each entry's two engines are reduced to a per-char class
// string and compared exactly. Degradations (date/time/2.) live here too —
// both engines degrade identically, which is the point. The two legitimate
// divergences are EXCLUDED here and pinned in section 4 instead.

const PARITY_CORPUS: Array<[string, string]> = [
  // comments
  ['line comment', '; hello'],
  ['double semicolon', ';; heading'],
  ['trailing comment', '(foo) ; tail'],
  ['inline block', '(foo #| in |# bar)'],
  ['block no-nest', '#| a #| b |# c |#'],
  ['multiline block', '#| one\ntwo |#'],
  // strings
  ['empty string', '""'],
  ['escaped quote', '"a\\"b"'],
  ['escaped backslash', '"a\\\\"'],
  ['unicode escape', '"a\\u{2728}b"'],
  ['bad escape (still string-family)', '"a\\qb"'],
  ['key/semicolon inside string', '":foo ; not"'],
  ['unterminated string', '"abc'],
  // raw strings
  ['raw one line', '"""x"""'],
  ['raw empty', '""""""'],
  ['raw greedy close', '""""abc"""'],
  ['raw multiline w/ inner quote', ':code """\nbody " x\n"""'],
  // numbers + units + degradations
  ['integer', '42'],
  ['negative', '-3'],
  ['float', '0.5'],
  ['trailing dot', '2.'],
  ['exponent', '1.5e-10'],
  ['unit deg', '90deg'],
  ['unit percent', '50%'],
  ['unit em (not exp)', '1em'],
  ['unit after exp', '1.5e+2hz'],
  ['underscores', '1_000_000'],
  ['adjacent units', '90deg5px'],
  ['hex integer', '0xFF'],
  ['hex upper prefix', '0Xff'],
  ['hex grouped', '0xFFFF_FFFF'],
  ['hex negative', '-0x10'],
  ['hex digit tail', '0x1F'],
  ['hex then symbol', '0xFFms'],
  ['bare hex prefix (degrades equally)', '0x'],
  ['hyphenated unit', '2d-array'],
  ['hyphenated unit, multi-run', '5ms-per-frame'],
  ['hyphen before a digit', '1em-2'],
  ['trailing hyphen', '2d-'],
  ['date (degrades equally)', '2026-06-09'],
  ['time (degrades equally)', '12:30:00'],
  ['vector of numbers', '[1 2 3]'],
  // keywords / symbols
  ['keyword operators', ':p+s'],
  ['keyword slashed', ':ns/k'],
  ['lone colon', ':'],
  ['keyword line', ':a :b'],
  // symbols with embedded/trailing digits — the bare-symbol fix keeps these plain
  ['type token f32', '(x f32)'],
  ['type token vec4f', '(x vec4f)'],
  ['type token mat4x4f', '(x mat4x4f)'],
  ['sharp note C#4', 'C#4'],
  ['leading dot .5', '.5'],
  // forms
  ['empty form', '()'],
  ['nested forms', '(a (b c))'],
  ['deep nest', '(a (b (c (d e))))'],
  ['double paren', '((a))'],
  ['space after paren', '( foo )'],
  ['keyword head', '(:foo)'],
  ['vector of forms', '[(a) (b)]'],
  ['atoms in vector', '[true false nil]'],
  ['non-head arg', '(x :n b)'],
  ['operator head', '(<= a b)'],
  ['arrow head', '(-> x y)'],
  ['dotted head', '(a.b c)'],
  ['plus head', '(+ 1 2)'],
  ['negative arg', '(f -3)'],
  ['head then digits', '(vec4f x)'],
  // realistic multi-construct
  ['mixed form', '(set :x 1.5e2hz :y true)'],
  ['comment then code', '; c\n(foo)'],
  // Manifest vocabulary added by the 1.2 format. Both engines colour a
  // head by position, never by a list of known heads, so a new form is
  // expected to need no grammar change at all — these two pin that,
  // because "no change needed" is a claim worth being able to re-check.
  ['cross-ref-provider declaration', '(cross-ref-provider :name uniforms :impl "wasm:x")'],
  ['provider-route cross-ref', '(cross-ref :target shader :provider uniforms :source-key src)'],
];

describe('CM ↔ TextMate per-character parity', () => {
  for (const [label, code] of PARITY_CORPUS) {
    it(`agrees on: ${label}`, async () => {
      assert.deepEqual(cmClasses(code), await tmClasses(code), code);
    });
  }
});

// ===========================================================================
// 4. Documented divergences (pinned)
// ===========================================================================
//
// The two places CM and TM legitimately differ. Pinned with the actual output
// of both so a change here is a conscious decision, and so the parity net above
// stays honest (these are the only inputs excluded from it). CM is the faithful
// engine in both — TM's are structural limits of a line-based grammar, and both
// are merely cosmetic.

describe('CM ↔ TextMate — documented divergences', () => {
  it('(A) a literal/number illegally in head position: CM=atom/number, TM=head', () => {
    // A reserved literal or number can't be a form head (LANGUAGE.md §2.3/§5.1),
    // so the input is degenerate. CM scopes the token for what it is; TM's form
    // begin-capture is head-agnostic and colours it as the head.
    assert.deepEqual(cmClasses('(true)'), ['paaaap']);
    assert.deepEqual(cmClasses('(-3)'), ['pnnp']);
  });
  it('(A) TextMate head-colours the same degenerate heads', async () => {
    assert.deepEqual(await tmClasses('(true)'), ['phhhhp']);
    assert.deepEqual(await tmClasses('(-3)'), ['phhp']);
  });

  it('(C) a head on the line AFTER `(`: CM carries state and colours it; TM cannot', async () => {
    // CM's `afterParen` survives the newline; a line-based TextMate grammar only
    // captures the head when it shares the opening `(`'s line.
    assert.deepEqual(cmClasses('(\n foo)'), ['p', '.hhhp']);
    assert.deepEqual(await tmClasses('(\n foo)'), ['p', '....p']);
  });
});
