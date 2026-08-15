// One-shot migrator: docs/tutorial/NN-*.md → src/content/tutorial/<part>/<chapter>/<lesson>/.
//
// Idempotent — overwrites any prior migration. Re-run after editing
// docs/tutorial/*.md to refresh the lesson content collection.
//
// What it does:
//   * Strips the leading H1 (`# 01 - Foo`) — the layout prints the title
//     from frontmatter / src/lib/lessons.ts.
//   * Strips the `## Goal` section — the lesson page no longer surfaces it.
//   * Strips the trailing `Next: [...](NN-foo.md)` line — the layout
//     generates prev/next navigation.
//   * Replaces the closing `## Mastery Check` checklist with a scored
//     multiple-choice quiz. Questions and answers come from the
//     MASTERY_QUIZZES map below.
//   * Writes a fresh `content.md` with type/title frontmatter.
//
// Run with `node scripts/migrate-tutorials.mjs` from the landing-page
// directory.

import fs from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const HERE = path.dirname(fileURLToPath(import.meta.url));
const ROOT = path.resolve(HERE, '..');
const TUT_SRC = path.resolve(ROOT, '..', 'docs', 'tutorial');
const TUT_DEST = path.resolve(ROOT, 'src', 'content', 'tutorial');

const LESSONS = [
  {
    num: '01',
    name: 'orientation',
    part: '1-foundations',
    chapter: '1-syntax',
    dir: '1-orientation',
    slug: 'orientation',
  },
  {
    num: '02',
    name: 'first-document',
    part: '1-foundations',
    chapter: '1-syntax',
    dir: '2-first-document',
    slug: 'first-document',
  },
  {
    num: '03',
    name: 'atoms-and-intent',
    part: '1-foundations',
    chapter: '1-syntax',
    dir: '3-atoms-and-intent',
    slug: 'atoms-and-intent',
  },
  {
    num: '04',
    name: 'numbers-units-vectors',
    part: '1-foundations',
    chapter: '1-syntax',
    dir: '4-numbers-units-vectors',
    slug: 'numbers-units-vectors',
  },
  {
    num: '05',
    name: 'forms-and-keyword-pairing',
    part: '1-foundations',
    chapter: '1-syntax',
    dir: '5-forms-and-keyword-pairing',
    slug: 'forms-and-keyword-pairing',
  },
  {
    num: '06',
    name: 'comments-and-strings',
    part: '1-foundations',
    chapter: '1-syntax',
    dir: '6-comments-and-strings',
    slug: 'comments-and-strings',
  },
  {
    num: '07',
    name: 'safe-expressions',
    part: '1-foundations',
    chapter: '2-expressions',
    dir: '1-safe-expressions',
    slug: 'safe-expressions',
  },
  {
    num: '08',
    name: 'bindings-and-control-flow',
    part: '1-foundations',
    chapter: '2-expressions',
    dir: '2-bindings-and-control-flow',
    slug: 'bindings-and-control-flow',
  },
  {
    num: '09',
    name: 'reading-plugin-schemas',
    part: '2-schemas',
    chapter: '1-reading',
    dir: '1-plugin-schemas',
    slug: 'reading-plugin-schemas',
  },
  {
    num: '10',
    name: 'discriminated-and-exclusive-forms',
    part: '2-schemas',
    chapter: '1-reading',
    dir: '2-discriminated-and-exclusive',
    slug: 'discriminated-and-exclusive-forms',
  },
  {
    num: '11',
    name: 'value-kinds-shapes',
    part: '2-schemas',
    chapter: '1-reading',
    dir: '3-value-kinds-shapes',
    slug: 'value-kinds-shapes',
  },
  {
    num: '12',
    name: 'value-kinds-refinements',
    part: '2-schemas',
    chapter: '1-reading',
    dir: '4-value-kinds-refinements',
    slug: 'value-kinds-refinements',
  },
  {
    num: '13',
    name: 'cross-references',
    part: '2-schemas',
    chapter: '1-reading',
    dir: '5-cross-references',
    slug: 'cross-references',
  },
  {
    num: '14',
    name: 'diagnostics-driven-repair',
    part: '2-schemas',
    chapter: '2-repair',
    dir: '1-diagnostics-driven-repair',
    slug: 'diagnostics-driven-repair',
  },
  {
    num: '15',
    name: 'style-portability-and-capstone',
    part: '2-schemas',
    chapter: '2-repair',
    dir: '2-style-portability-capstone',
    slug: 'style-portability-capstone',
  },
];

function deriveTitle(src) {
  const m = /^#\s+\d+\s*[-–—]\s*(.+?)\s*$/m.exec(src);
  return m ? m[1] : 'Untitled';
}

function stripFrame(src) {
  let body = src.replace(/^#\s+\d+\s*[-–—]\s*.+\r?\n/m, '');
  // Drop the entire `## Goal` section — runs from the heading until
  // the next H2 (or end of file). Lesson page no longer surfaces it.
  body = body.replace(/^##\s+Goal\b[^\n]*\n[\s\S]*?(?=^##\s|\Z)/m, '');
  body = body.replace(/\r?\n+Next:\s*\[[^\]]+\]\([^)]+\)\.?\s*$/m, '');
  // `sjon` fences pass through untouched: Astro's markdown Shiki now loads the
  // SJON TextMate grammar (astro.config.mjs `shikiConfig.langs`), so the docs
  // highlight natively instead of approximating with Clojure.
  return body.replace(/^\s+/, '').replace(/\s+$/, '') + '\n';
}

// Inline markdown → HTML for the limited subset that appears inside
// Mastery Check bullets: backtick code spans and emphasis.
// We do not run a full markdown parser — these run inside raw HTML, so
// astro's markdown processor won't touch them.
function inlineMdToHtml(s) {
  let out = '';
  let i = 0;
  while (i < s.length) {
    const ch = s[i];
    if (ch === '`') {
      const end = s.indexOf('`', i + 1);
      if (end !== -1) {
        out += `<code>${escapeHtml(s.slice(i + 1, end))}</code>`;
        i = end + 1;
        continue;
      }
    }
    if (ch === '*' && s[i + 1] === '*') {
      const end = s.indexOf('**', i + 2);
      if (end !== -1) {
        out += `<strong>${inlineMdToHtml(s.slice(i + 2, end))}</strong>`;
        i = end + 2;
        continue;
      }
    }
    if (ch === '*') {
      const end = s.indexOf('*', i + 1);
      if (end !== -1) {
        out += `<em>${inlineMdToHtml(s.slice(i + 1, end))}</em>`;
        i = end + 1;
        continue;
      }
    }
    out += escapeHtml(ch);
    i++;
  }
  return out;
}

function escapeHtml(s) {
  return s
    .replace(/&/g, '&amp;')
    .replace(/</g, '&lt;')
    .replace(/>/g, '&gt;')
    .replace(/"/g, '&quot;');
}

// Hand-authored multiple-choice questions per lesson slug. Source of
// truth lives here (not in docs/tutorial/*.md) because the source
// markdown only has open-ended prompts. The `correct` field is the
// 0-based index into `options`.
const MASTERY_QUIZZES = {
  orientation: [
    {
      q: 'Can a document have more than one root?',
      options: [
        'Yes — a document is a sequence of root values.',
        'No — every document must have exactly one root form.',
        'Only if separated by a blank line.',
      ],
      correct: 0,
    },
    {
      q: 'Does a `.sjon` file import plugins?',
      options: [
        'No — the host loads plugins; the file just uses their vocabulary.',
        'Yes, with an `(import ...)` form at the top.',
        'Only when the document begins with `(plugins ...)`.',
      ],
      correct: 0,
    },
    {
      q: 'Is `(* 2 4)` always evaluated just because it looks like arithmetic?',
      options: [
        'Yes — any list whose head is `*` is multiplied automatically.',
        'Only inside `(let ...)` blocks.',
        'No — it is just a form in source; it becomes an expression only when the active schema and host say so.',
      ],
      correct: 2,
    },
    {
      q: 'Where can a kvpair appear?',
      options: [
        'At the top level, between root forms.',
        "Only inside a form, as a `:key value` pair among the form's children.",
        'Inside a vector, between two values.',
      ],
      correct: 1,
    },
  ],
  'first-document': [
    {
      q: 'What are the roots in a document with three top-level `(layer ...)` forms?',
      options: [
        'Zero roots — only one root is permitted in a document.',
        'One root holding three children.',
        'Three roots — each `(layer ...)` is its own top-level value.',
      ],
      correct: 2,
    },
    {
      q: 'Does indentation change the tree?',
      options: [
        'No — only parens and brackets shape the tree; whitespace is for readers.',
        'Yes — children must be indented under their parent.',
        'Only inside vectors.',
      ],
      correct: 0,
    },
    {
      q: 'Why do keys-first documents make later edits easier to review?',
      options: [
        'They run faster through the parser.',
        'Each `:key value` line stands on its own, so diffs and reorderings stay local.',
        'They take less disk space.',
      ],
      correct: 1,
    },
  ],
  'atoms-and-intent': [
    {
      q: 'Which value kind should you use for a filename?',
      options: [
        'A symbol like `intro.sjon`.',
        'A keyword like `:intro.sjon`.',
        'A string like `"intro.sjon"`.',
      ],
      correct: 2,
    },
    {
      q: 'Which value kind should you use for a closed enum-like option?',
      options: [
        'A keyword like `:overlay`.',
        'A string like `"overlay"`.',
        'A symbol like `overlay`.',
      ],
      correct: 2,
      explanations: [
        'Keywords are slot labels or flags, never kvpair values. `:projection :overlay` parses as two adjacent positional flags, not `projection = :overlay`.',
        'A string would work, but it tells the schema "free-form text," not "one of a closed set." Use strings for opaque labels, not enum members.',
        'Symbols carry author intent for *named choices in a closed vocabulary* — exactly what an enum is. The schema can validate the symbol against a member set.',
      ],
    },
    {
      q: 'Why is `:projection :ortho` not a reliable way to write an option?',
      options: [
        "Two consecutive keywords don't pair into a kvpair — `:ortho` becomes a separate flag, not the value of `:projection`.",
        'SJON forbids two keywords in a row.',
        'It is reliable; both spellings are equivalent.',
      ],
      correct: 0,
    },
    {
      q: 'Are `:bpm` and `:BPM` the same keyword?',
      options: [
        'Yes — keyword comparison is case-insensitive.',
        'Only if the schema says so.',
        'No — keywords compare byte-for-byte, so casing matters.',
      ],
      correct: 2,
    },
    {
      q: 'Is `C#4` a valid symbol? Is `#C4`?',
      options: [
        'Both are valid symbols.',
        '`C#4` is a valid symbol; `#C4` is not, because symbols cannot start with `#`.',
        'Neither is a valid symbol.',
      ],
      correct: 1,
    },
  ],
  'numbers-units-vectors': [
    {
      q: 'Does SJON itself know that `ms` means milliseconds?',
      options: [
        'No — units are opaque tags; the host plugin decides what each suffix means.',
        'Yes — `ms` is a built-in unit.',
        'Only if the document declares `:units (ms ...)`.',
      ],
      correct: 0,
    },
    {
      q: 'What is the difference between `1e9` and `1em`?',
      options: [
        'They are equivalent — both are numbers in scientific notation.',
        '`1em` is CSS-only; SJON rejects it.',
        '`1e9` is a number in scientific notation; `1em` is a number with a unit suffix.',
      ],
      correct: 2,
    },
    {
      q: 'Is `[0 0 1 1]` the same shape as `[[0 0] [1 1]]`?',
      options: [
        'No — the first is a flat 4-vector; the second is a vector of two 2-vectors.',
        'Yes — vectors flatten automatically.',
        'Only when nested under `:points`.',
      ],
      correct: 0,
    },
    {
      q: 'Can vector elements be forms?',
      options: [
        'No — vectors hold only atoms and other vectors.',
        'Yes — vectors hold any value, including forms (e.g., expressions).',
        'Only inside `(let ...)`.',
      ],
      correct: 1,
    },
  ],
  'forms-and-keyword-pairing': [
    {
      q: 'What does `(stack :mode :mask)` parse as?',
      options: [
        'A `stack` form with two positional flags `:mode` and `:mask` — a keyword can never be the value of a kvpair.',
        'A `stack` form with a kvpair `:mode :mask`.',
        'A syntax error.',
      ],
      correct: 0,
    },
    {
      q: 'How do you write an enum-like value in a kvpair?',
      options: [
        'Use two keywords back-to-back: `:projection :ortho`.',
        'Wrap the option in parens: `:projection (ortho)`.',
        'Use a symbol or string for the value: `:projection ortho` or `:projection "ortho"`.',
      ],
      correct: 2,
    },
    {
      q: 'Where can a keyword safely be used as a value?',
      options: [
        'In a kvpair after another `:key`.',
        'As a positional flag — i.e., as a child of a form, not the value of a kvpair.',
        'Anywhere; SJON makes no distinction.',
      ],
      correct: 1,
    },
    {
      q: 'Why do forms with no positional children expose keyword-pairing mistakes quickly?',
      options: [
        'A stray bare keyword has nowhere legitimate to live, so the schema flags it as a positional child.',
        'They have stricter parsers.',
        'They run a second validation pass.',
      ],
      correct: 0,
    },
  ],
  'comments-and-strings': [
    {
      q: 'When should you prefer raw strings (`"""..."""`)?',
      options: [
        'Always — they are faster to parse.',
        'When escaping would obscure the payload (shaders, regex, paths with backslashes, markup).',
        'When the string is short.',
      ],
      correct: 1,
    },
    {
      q: 'Does raw string content process `\\n` escapes?',
      options: [
        'No — raw strings keep their bytes verbatim; `\\n` stays as a backslash and an `n`.',
        'Yes — escapes work in both surfaces.',
        'Only inside a `(raw ...)` block.',
      ],
      correct: 0,
    },
    {
      q: 'Can block comments nest?',
      options: [
        'No — the first `|#` always closes the outermost `#|`.',
        'Only if the parser is told to.',
        'Yes — `#| ... #| inner |# ... |#` is allowed; comments nest properly.',
      ],
      correct: 0,
      explanations: [
        'Correct. `LANGUAGE.md` §2.2 is explicit: "Block comments do not nest." The lexer treats `|#` as the closer for the *outermost* open `#|`.',
        'No — the parser has no nesting mode. Block-comment lexing is fixed.',
        'This would require a counter in the lexer; SJON keeps the lexer single-pass and labeled-switch. If you need a long comment, use multiple `#| ... |#` blocks back-to-back.',
      ],
    },
  ],
  'safe-expressions': [
    {
      q: 'Can a safe expression appear as a vector element?',
      options: [
        'No — only literals are allowed inside vectors.',
        'Only if the vector is wrapped in `(expr ...)`.',
        'Yes — a vector holds any value, so a form (expression) can sit alongside literals.',
      ],
      correct: 2,
    },
    {
      q: 'Why is `(lerp 0 :to 10 0.5)` invalid?',
      options: [
        'A labeled call is all-or-nothing — mixing positional and labeled arguments produces `expr_mixed_args`.',
        'The numbers are out of range.',
        '`lerp` does not exist.',
      ],
      correct: 0,
    },
    {
      q: 'Why can `(vec3 1 "x" 3)` fail validation before evaluation?',
      options: [
        '`vec3` only accepts symbols.',
        'The signature is typed — the validator catches the literal `"x"` where a number is required.',
        'Strings are illegal in expressions.',
      ],
      correct: 1,
    },
    {
      q: 'What does `(or false nil)` return?',
      options: [
        '`true`.',
        'It raises an error.',
        '`nil` — both branches are falsy, so `or` falls through and returns the last value.',
      ],
      correct: 2,
    },
    {
      q: 'What values are falsy in safe expressions?',
      options: [
        'Only `nil` and `false`.',
        '`0`, `""`, `nil`, and `false`.',
        'Any value not equal to `true`.',
      ],
      correct: 0,
    },
  ],
  'bindings-and-control-flow': [
    {
      q: 'Can a later `let` binding refer to an earlier one?',
      options: [
        'Yes — bindings are sequential; later names see earlier ones.',
        'No — `let` bindings are unordered.',
        'Only if wrapped in another `let`.',
      ],
      correct: 0,
    },
    {
      q: 'Can an earlier `let` binding refer to a later one?',
      options: [
        'Yes — `let` is mutually recursive.',
        'No — earlier bindings cannot see names introduced later in the same `let`.',
        'Only inside `cond`.',
      ],
      correct: 1,
    },
    {
      q: 'What supplies `t` in an expression like `(clamp t 0 1)`?',
      options: [
        'It defaults to `0` when undefined.',
        'It refers to the literal symbol `t`.',
        'A surrounding `let` or a host-supplied binding provides `t`.',
      ],
      correct: 2,
    },
    {
      q: 'When should expression logic move out of SJON?',
      options: [
        'Whenever it uses `if` or `cond`.',
        'When the logic needs side effects, recursion, I/O, or general computation — those belong in the host.',
        'Never — SJON is Turing-complete.',
      ],
      correct: 1,
    },
  ],
  'reading-plugin-schemas': [
    {
      q: 'What does `positional: none` mean for authors?',
      options: [
        'The form takes no kvpair children.',
        'The form does not accept positional (non-key) children — only `:key value` pairs.',
        'The form must be empty.',
      ],
      correct: 1,
    },
    {
      q: 'Does `open: true` silence duplicate-key or type errors?',
      options: [
        'No — `open: true` only allows unknown keys; declared keys still enforce types and duplicate rules.',
        'Yes — open forms accept anything.',
        'Only on discriminated forms.',
      ],
      correct: 0,
    },
    {
      q: 'Does a `.sjon` file itself choose the plugin set?',
      options: [
        'Yes — the file imports plugins explicitly.',
        'Only when a `(plugins ...)` form is present.',
        'No — the host loads plugins; the file just uses their vocabulary.',
      ],
      correct: 2,
    },
  ],
  'discriminated-and-exclusive-forms': [
    {
      q: 'On a discriminated form, why must the discriminant key appear before variant-only keys?',
      options: [
        "Until the discriminant is known, the validator can't tell which variant's keys are legal — variant-only keys before it produce `unknown_key` with a discriminant-first hint.",
        'For readability only.',
        'It is a parser limitation.',
      ],
      correct: 0,
    },
    {
      q: 'For an `exactly-one` exclusive group, what distinguishes the "both present" diagnostic from the "neither present" one?',
      options: [
        'They share one code; only the message differs.',
        'They are distinct codes — `mutually_exclusive_keys_present` for too many, `required_one_of_missing` for too few.',
        'Only "both present" produces a diagnostic.',
      ],
      correct: 1,
    },
    {
      q: 'What does a partial multi-key exclusive bundle produce?',
      options: [
        '`exclusive_bundle_partial` — some keys in the bundle are present and the rest are missing.',
        '`required_one_of_missing` — partial bundles are treated as completely absent.',
        '`duplicate_key` — the bundle counts as writing the same key twice.',
      ],
      correct: 0,
    },
    {
      q: 'What happens if an `open: true` form declares an exclusive group?',
      options: [
        'The group still fires; openness only affects unknown keys.',
        'The group does not fire — open forms skip closed-shape cardinality sweeps.',
        'Only `at-most-one` groups fire.',
      ],
      correct: 1,
    },
  ],
  'value-kinds-shapes': [
    {
      q: 'Is a plugin-declared value kind a new SJON syntax feature?',
      options: [
        'Yes — each named kind adds new surface syntax.',
        'No — value kinds are contracts on existing shapes (number, string, symbol, vector, form, union).',
        'Only when prefixed with the kind name.',
      ],
      correct: 1,
    },
    {
      q: 'When reading a named kind, what should you check first?',
      options: [
        'The error code list.',
        'The default value.',
        'The underlying shape — is the value a number, string, symbol, vector, form, or union?',
      ],
      correct: 2,
    },
    {
      q: 'Which diagnostic points to a missing required unit suffix?',
      options: ['`unit_required`.', '`wrong_underlying`.', '`not_member`.'],
      correct: 0,
    },
    {
      q: 'Which diagnostic points to a vector with the wrong number of elements?',
      options: ['`number_above_max`.', '`vector_length_mismatch`.', '`string_too_short`.'],
      correct: 1,
    },
    {
      q: 'A slot is typed `attribute: vector, length 2-4, element number`. Which value is rejected?',
      options: [
        '`[0.0 1.0 0.5]` (three elements).',
        '`[0.0]` (one element).',
        '`[0.0 1.0 0.5 1.0]` (four elements).',
      ],
      correct: 1,
      explanations: [
        'Three elements sits inside the 2-4 window, so this is accepted.',
        'Correct. One element is below the minimum of 2, so it fires `vector_too_short`.',
        'Four elements is the top of the 2-4 window, so this is accepted.',
      ],
    },
    {
      q: 'A number kind sets `unit rejected`. What does it accept?',
      options: [
        'Only a bare number with no unit suffix.',
        'Any number, with or without a unit.',
        'Only a number with the `f` suffix.',
      ],
      correct: 0,
      explanations: [
        'Correct. A reject kind takes a bare number; any suffix fires `unit_forbidden`.',
        'No - rejecting units is the opposite of allowing them, so a suffix is an error.',
        'No - `f` is itself a unit suffix, and a reject kind forbids every suffix.',
      ],
    },
    {
      q: 'A value typed `repr u16` is rejected. What should you check about the number?',
      options: [
        'Whether it is a quoted string.',
        'Whether it is in range `[0, 65535]` and a whole number.',
        'Whether it carries a unit suffix.',
      ],
      correct: 1,
      explanations: [
        'String-vs-number is a different failure (`wrong_underlying`); a repr tag is about the number itself.',
        'Correct. A `u16` repr checks range (`[0, 65535]`) and, being an integer type, integrality - `repr_out_of_range` covers both.',
        'Units are a separate axis (`unit_*`); a repr failure is `repr_out_of_range`.',
      ],
    },
  ],
  'value-kinds-refinements': [
    {
      q: 'What does a member set usually mean for authoring?',
      options: [
        'You must use one of a closed list of symbol or string values declared by the plugin.',
        'You may write any symbol; the plugin will accept it.',
        'The slot accepts any number.',
      ],
      correct: 0,
    },
    {
      q: 'What does `union_no_branch_matched` tell you to reread?',
      options: [
        'The plugin manifest version.',
        'The list of alternatives the message names — the slot accepts each shape; rewrite the value to fit one of them.',
        'The whole document from scratch.',
      ],
      correct: 1,
    },
    {
      q: 'When a union slot lists `form` as one alternative, does that mean any parenthesized construct is accepted?',
      options: [
        'Yes — any form satisfies the slot.',
        'Only if the form is empty.',
        'No — a typed form alternative usually narrows further (e.g., a head set or a discriminated form).',
      ],
      correct: 2,
    },
    {
      q: 'What does a head set constrain?',
      options: [
        'The spelling of a nested form head, such as `circle` or `rect`.',
        'The keywords allowed on the parent form.',
        'The number of vector elements.',
      ],
      correct: 0,
    },
    {
      q: 'A slot typed `dim: scalar-or-ref, base dim-value` (a number base). Which value takes the reference branch?',
      options: [
        'The string `"WORKGROUP_SIZE"`.',
        'The bare symbol `WORKGROUP_SIZE`.',
        'The keyword `:WORKGROUP_SIZE`.',
      ],
      correct: 1,
      explanations: [
        'A quoted string is neither a number nor a symbol, so it fires `union_no_branch_matched`.',
        'Correct. `scalar-or-ref` expands to `union dim-value | symbol`; a bare symbol takes the reference branch.',
        'A keyword is not one of the branches; the reference branch is a bare symbol.',
      ],
    },
    {
      q: 'A `:shape` slot defines local forms `circle | rect`. The document writes `(canvas :shape (triangle))`. What happens?',
      options: [
        'It is accepted - any form works in a form slot.',
        'It fires `unknown_local_form` - the head is neither a local form nor a global one.',
        'It fires `not_head_member` - the head is outside the list.',
      ],
      correct: 1,
      explanations: [
        'A slot-local set narrows the choices, so an arbitrary head is not accepted.',
        'Correct. The head matches no local form and no global form, so the slot-scoped `unknown_local_form` fires - more specific than `unknown_form`.',
        '`not_head_member` is for a head set (a closed list of global heads); a slot that defines forms inline reports `unknown_local_form`.',
      ],
    },
  ],
  'cross-references': [
    {
      q: 'What are the two sides of a cross-reference?',
      options: [
        'Reader side and writer side.',
        'A declaration that introduces a name, and a reference that uses it.',
        'A schema side and a host side.',
      ],
      correct: 1,
    },
    {
      q: 'Why can a reference appear before the form it names?',
      options: [
        'The validator runs in two passes — it builds the registry first, then checks references.',
        'Order is enforced; the reference must follow the declaration.',
        'Only when the reference is a string.',
      ],
      correct: 0,
    },
    {
      q: 'Why does a typo on a phrase reference produce `not_cross_ref` instead of `not_member`?',
      options: [
        'They mean the same thing.',
        'Because the plugin author chose a different code.',
        'The legal values come from the document\'s declarations, not from a closed plugin set — the diagnostic distinguishes "no such reference" from "not in the member list".',
      ],
      correct: 2,
    },
    {
      q: 'Why is `"p0"` not the same declaration as `p0`?',
      options: [
        'Strings and symbols are different value kinds; cross-reference targets are symbols.',
        'They are the same — strings and symbols interchange.',
        'Only when wrapped in a form.',
      ],
      correct: 0,
    },
    {
      q: 'What is the first repair to try for `cross_ref_outside_scope`?',
      options: [
        'Rename the declaration.',
        'Move the reference inside the enclosing scope form, or declare the name in the right scope.',
        'Quote the symbol.',
      ],
      correct: 1,
    },
    {
      q: 'Where does a provider-backed kind get its legal names from?',
      options: [
        'Whatever the provider finds in the environment - files on disk, a live database, a running service.',
        'A closed list the plugin writes down, like a member set.',
        'The string inside the document that the provider is handed, and nothing else.',
      ],
      correct: 2,
      explanations: [
        'That would be an environmental check, not validation. A provider never sees the filesystem, the network, or the clock - two hosts validating the same file have to reach the same answer.',
        'That is a member set (chapter 12). A provider route computes the list per document, from a string in it.',
        'Correct. The provider receives one string - the value under `:source-key` - and reports the names in it.',
      ],
    },
    {
      q: 'A provider rejects a shader source, and `cross_ref_extraction_failed` fires on that string. Why is the reference to a uniform not also reported?',
      options: [
        'Because the member set was never computed, so the reference is unchecked - not accepted, and not rejected.',
        'Because references are only checked once per document.',
        'It is reported, as a second `not_cross_ref` on the same line.',
      ],
      correct: 0,
    },
  ],
  'diagnostics-driven-repair': [
    {
      q: 'Which diagnostic category usually means you misspelled a key?',
      options: ['`wrong_underlying`.', '`unknown_key`.', '`union_no_branch_matched`.'],
      correct: 1,
    },
    {
      q: 'Which category points to a closed enum-like value?',
      options: ['`not_member`.', '`expr_kvpair_not_allowed`.', '`positional_not_allowed`.'],
      correct: 0,
    },
    {
      q: 'Why should tooling match diagnostic codes rather than message prose?',
      options: [
        'Codes are shorter to type.',
        'Prose is localized; codes are not.',
        'Codes are the stable contract - message prose may change between releases.',
      ],
      correct: 2,
    },
    {
      q: 'Why can `positional_not_allowed` be caused by keyword pairing?',
      options: [
        'When two keywords sit next to each other neither pairs into a kvpair, so they become positional flags - and a form that disallows positional children flags them.',
        "It can't - pairing always succeeds.",
        'Only when expressions are involved.',
      ],
      correct: 0,
    },
    {
      q: 'For an `exactly-one` exclusive group, which two codes cover "too many" vs. "too few"?',
      options: [
        '`unknown_key` and `missing_required_key`.',
        '`mutually_exclusive_keys_present` (too many) and `required_one_of_missing` (too few).',
        '`duplicate_key` and `not_member`.',
      ],
      correct: 1,
    },
    {
      q: 'A vector value is rejected. Which diagnostic tells you the slot has a fixed length rather than a variable-length range?',
      options: [
        '`vector_length_mismatch` (fixed `:len`); a range fires `vector_too_short` / `vector_too_long`.',
        '`vector_too_short` for both fixed and variable slots.',
        '`wrong_underlying` in every case.',
      ],
      correct: 0,
      explanations: [
        'Correct. A fixed `:len` fires `vector_length_mismatch`; a `:min-len`/`:max-len` range fires `vector_too_short` or `vector_too_long` at the edges.',
        '`vector_too_short` is the variable-length floor only - a fixed-length slot reports `vector_length_mismatch`.',
        '`wrong_underlying` means the value was not a vector at all; here the value is a vector of the wrong length.',
      ],
    },
    {
      q: 'What separates `unit_not_allowed` from `unit_forbidden`?',
      options: [
        'They are the same code under two names.',
        '`unit_not_allowed` means the suffix is outside an allowed list; `unit_forbidden` means the kind rejects every unit.',
        '`unit_forbidden` is only for dates.',
      ],
      correct: 1,
      explanations: [
        'They are distinct, wire-stable codes for distinct rules.',
        'Correct. An allowed list rejects an off-list suffix with `unit_not_allowed`; a reject kind takes bare numbers only and fires `unit_forbidden` for any suffix.',
        'No - `unit_forbidden` fires on a number-underlying kind that rejects all unit suffixes, closing the `1.0f -> 0` trap.',
      ],
    },
    {
      q: 'Why does a bad form head inside a slot with local forms produce `unknown_local_form` rather than `unknown_form`?',
      options: [
        'The slot narrowed the choices, so the message can list the local heads it accepts.',
        'It is a typo for `unknown_form`.',
        'Local forms disable the global vocabulary entirely.',
      ],
      correct: 0,
      explanations: [
        'Correct. The slot carries its own local form set, so the resolver reports `unknown_local_form` and names the local heads (the global fallback still applies).',
        'They are separate codes: `unknown_local_form` is the slot-scoped version, more specific than the top-level `unknown_form`.',
        'Local forms are additive - a non-local head still falls back to the global vocabulary; only a head matching neither fails.',
      ],
    },
  ],
  'style-portability-capstone': [
    {
      q: 'What should every keyword in your capstone be?',
      options: [
        'Either a key in a kvpair, or a deliberate flag whose role you can name.',
        'Either decorative or required.',
        'Only flags; kvpairs are optional.',
      ],
      correct: 0,
    },
    {
      q: 'How do you make local bare heads more portable?',
      options: [
        'Move them to a string.',
        'Wrap them in `:head`.',
        'Qualify them with a plugin namespace, e.g., `plugin/head`.',
      ],
      correct: 2,
    },
    {
      q: 'What is the right way to break and repair your own document?',
      options: [
        'Read the prose message and guess.',
        'Use diagnostic codes — they map directly to repair direction.',
        'Reformat the file and re-run.',
      ],
      correct: 1,
    },
  ],
};

// Replace the trailing `## Mastery Check\n\n- ...\n- ...` block with a
// raw-HTML <section class="mastery-quiz"> block. Source bullets are
// ignored; questions come from MASTERY_QUIZZES indexed by lessonSlug.
function rewriteMasteryCheck(body, lessonSlug) {
  const re = /\n##\s+Mastery Check[ \t]*\n+([\s\S]+)$/;
  const m = re.exec(body);
  if (!m) return body;

  const quiz = MASTERY_QUIZZES[lessonSlug];
  if (!quiz || quiz.length === 0) {
    // Fallback: drop the section silently rather than emit broken HTML.
    return body.slice(0, m.index);
  }

  const items = quiz
    .map((entry, i) => {
      const name = `q-${lessonSlug}-${i}`;
      const opts = entry.options
        .map((opt, j) => {
          const expl = entry.explanations?.[j];
          const explLine = expl
            ? `        <p class="mc-explanation" hidden>${inlineMdToHtml(expl)}</p>`
            : null;
          return [
            '      <li>',
            `        <label><input type="radio" name="${name}" value="${j}" /> <span>${inlineMdToHtml(opt)}</span></label>`,
            ...(explLine ? [explLine] : []),
            '      </li>',
          ].join('\n');
        })
        .join('\n');
      return [
        `    <li class="mc-item" data-correct="${entry.correct}">`,
        `      <p class="mc-q">${inlineMdToHtml(entry.q)}</p>`,
        '      <ul class="mc-options">',
        opts,
        '      </ul>',
        '      <p class="mc-feedback" hidden></p>',
        '    </li>',
      ].join('\n');
    })
    .join('\n');

  const html = [
    '',
    `<section class="mastery-quiz" data-lesson="${lessonSlug}">`,
    '  <h2>Mastery Check</h2>',
    '  <ol class="mc-list">',
    items,
    '  </ol>',
    '  <div class="mc-controls">',
    '    <button type="button" class="mc-submit">Submit answers</button>',
    '    <button type="button" class="mc-reset" hidden>Reset</button>',
    '    <p class="mc-score" hidden></p>',
    '  </div>',
    '</section>',
    '',
  ].join('\n');

  return body.slice(0, m.index) + html;
}

async function ensureDir(p) {
  await fs.mkdir(p, { recursive: true });
}

// Per-slug post-processors. Most lessons need none; the diagnostics
// repair lesson wraps the
// codes table in a sticky container so it stays in view while the
// reader scrolls through worked examples below it.
const LESSON_PATCHES = {
  'diagnostics-driven-repair': (body) => {
    // Locate the markdown table that begins after `Stable codes you are
    // likely to see…` and ends at the first non-table blank line.
    const tableStart = body.indexOf('| Code |');
    if (tableStart === -1) return body;
    const after = body.indexOf('\n\n', tableStart);
    if (after === -1) return body;
    const before = body.lastIndexOf('\n', tableStart - 1);
    const head = body.slice(0, before + 1);
    const table = body.slice(before + 1, after);
    const tail = body.slice(after);
    // Blank lines around the wrapped table are required so the
    // markdown processor still recognises the inner GFM table.
    return [head, '<div class="codes-sticky">\n\n', table, '\n\n</div>', tail].join('');
  },
};

// Append a "Open in playground →" deep link below each fenced SJON
// block. The /playground page reads the base64url-encoded snippet from
// `location.hash` and seeds the editor. Only applied to early lessons
// (1-8); later lessons reference schemas the playground doesn't have
// loaded, so diagnostics would be noisy.
function injectPlaygroundLinks(body) {
  return body.replace(/```sjon\n([\s\S]*?)\n```/g, (match, snippet) => {
    const encoded = Buffer.from(snippet.trim(), 'utf8').toString('base64url');
    return `${match}\n\n[Open in playground →](/playground#s=${encoded})`;
  });
}

async function migrate() {
  let migrated = 0;
  for (const lesson of LESSONS) {
    const srcPath = path.join(TUT_SRC, `${lesson.num}-${lesson.name}.md`);
    const src = await fs.readFile(srcPath, 'utf8');
    const title = deriveTitle(src);
    let body = stripFrame(src);
    body = rewriteMasteryCheck(body, lesson.slug);
    if (Number(lesson.num) <= 8) body = injectPlaygroundLinks(body);
    const patch = LESSON_PATCHES[lesson.slug];
    if (patch) body = patch(body);

    const lessonDir = path.join(TUT_DEST, lesson.part, lesson.chapter, lesson.dir);
    await ensureDir(lessonDir);

    const escTitle = title.replace(/'/g, "\\'");
    const frontmatter = ['---', 'type: lesson', `title: '${escTitle}'`, '---', '', ''].join('\n');

    await fs.writeFile(path.join(lessonDir, 'content.md'), frontmatter + body);

    migrated++;
    console.log(`  ${lesson.num}  ${title}`);
  }

  console.log(`\nMigrated ${migrated} lesson(s).`);
}

migrate().catch((err) => {
  console.error(err);
  process.exit(1);
});
