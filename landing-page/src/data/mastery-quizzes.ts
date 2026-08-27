// Hand-authored multiple-choice questions, one list per lesson slug.
//
// The source of truth is here rather than in docs/tutorial/*.md because the
// source markdown carries open-ended prompts — "can you say why…" — which a
// reader answers to themselves. These are the scorable version of the same
// checks, and `src/lib/quiz-html.ts` renders them into the lesson body in
// place of the `## Mastery Check` section.

/** One question. `correct` is a 0-based index into `options`. */
export interface QuizQuestion {
  q: string;
  options: readonly string[];
  /** Index into `options`. Validated below — see the note there. */
  correct: number;
  /** Optional per-option prose, revealed after answering. Parallel to
   *  `options`; a shorter array simply leaves the rest unexplained. */
  explanations?: readonly string[];
}

export const MASTERY_QUIZZES: Readonly<Record<string, readonly QuizQuestion[]>> = {
  orientation: [
    {
      q: 'Can a document have more than one root?',
      options: [
        'Yes. A document is a sequence of root values.',
        'No. Every document must have exactly one root form.',
        'Only if separated by a blank line.',
      ],
      correct: 0,
    },
    {
      q: 'Does a `.sjon` file import plugins?',
      options: [
        'No. The host loads plugins; the file just uses their vocabulary.',
        'Yes, with an `(import ...)` form at the top.',
        'Only when the document begins with `(plugins ...)`.',
      ],
      correct: 0,
    },
    {
      q: 'Is `(* 2 4)` always evaluated just because it looks like arithmetic?',
      options: [
        'Yes. Any list whose head is `*` is multiplied automatically.',
        'Only inside `(let ...)` blocks.',
        'No. It is just a form in source; it becomes an expression only when the active schema and host say so.',
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
        'Zero roots, because only one root is permitted in a document.',
        'One root holding three children.',
        'Three roots, because each `(layer ...)` is its own top-level value.',
      ],
      correct: 2,
    },
    {
      q: 'Does indentation change the tree?',
      options: [
        'No. Only parens and brackets shape the tree; whitespace is for readers.',
        'Yes. Children must be indented under their parent.',
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
        'Symbols carry author intent for *named choices in a closed vocabulary*, which is exactly what an enum is. The schema can validate the symbol against a member set.',
      ],
    },
    {
      q: 'Why is `:projection :ortho` not a reliable way to write an option?',
      options: [
        "Two consecutive keywords don't pair into a kvpair, so `:ortho` becomes a separate flag rather than the value of `:projection`.",
        'SJON forbids two keywords in a row.',
        'It is reliable; both spellings are equivalent.',
      ],
      correct: 0,
    },
    {
      q: 'Are `:bpm` and `:BPM` the same keyword?',
      options: [
        'Yes. Keyword comparison is case-insensitive.',
        'Only if the schema says so.',
        'No. Keywords compare byte-for-byte, so casing matters.',
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
        'No. Units are opaque tags; the host plugin decides what each suffix means.',
        'Yes. `ms` is a built-in unit.',
        'Only if the document declares `:units (ms ...)`.',
      ],
      correct: 0,
    },
    {
      q: 'What is the difference between `1e9` and `1em`?',
      options: [
        'They are equivalent, because both are numbers in scientific notation.',
        '`1em` is CSS-only; SJON rejects it.',
        '`1e9` is a number in scientific notation; `1em` is a number with a unit suffix.',
      ],
      correct: 2,
    },
    {
      q: 'Is `[0 0 1 1]` the same shape as `[[0 0] [1 1]]`?',
      options: [
        'No. The first is a flat 4-vector; the second is a vector of two 2-vectors.',
        'Yes. Vectors flatten automatically.',
        'Only when nested under `:points`.',
      ],
      correct: 0,
    },
    {
      q: 'Can vector elements be forms?',
      options: [
        'No. Vectors hold only atoms and other vectors.',
        'Yes. Vectors hold any value, including forms (e.g., expressions).',
        'Only inside `(let ...)`.',
      ],
      correct: 1,
    },
    {
      q: 'Why is `10x` not a hex literal?',
      options: [
        'It is: `10x` is 16 in hexadecimal.',
        'The `0x` prefix is only recognised after a lone `0`, so elsewhere `x` is an ordinary unit letter: `10x` is the number 10 with unit `x`.',
        'Hex needs at least two digits after the prefix.',
      ],
      correct: 1,
      explanations: [
        'No. There is no `0x` prefix here at all: the lexeme is the digits `10` followed by the unit letter `x`.',
        'Correct, and the narrowness is the point: gating the prefix on a bare `0` (optionally signed) is what lets hex be added without changing how a single pre-existing document reads.',
        'Hex needs exactly one digit minimum, so `0xF` is fine. The digit count is not what disqualifies `10x`.',
      ],
    },
    {
      q: '`2d-array` is one value and `1em-2` is two. What single rule decides both?',
      options: [
        'Hyphens are allowed inside a unit, and `2` is not a valid unit character.',
        'Inside a unit, a hyphen continues the suffix only when the next byte is an ASCII letter; otherwise it ends the token.',
        'The lexer looks the unit up against a table of known units.',
      ],
      correct: 1,
      explanations: [
        'Close, but stated backwards: the rule is about what follows the hyphen, not about which bytes may appear in a unit. A trailing `2d-` also ends at `2d`, and nothing about `2` being invalid explains that.',
        'Correct, and the narrowness is the point: it is the smallest rule that gets `2d-array` while leaving every previously-valid input reading exactly as it did.',
        'Units are opaque to the substrate. SJON never interprets one, so there is no table to consult, and a plugin decides which units it accepts long after lexing.',
      ],
    },
    {
      q: 'What does `sjon fmt` print for `0xFF`, and why?',
      options: [
        '`0xFF`, because the formatter preserves the source spelling of every literal.',
        '`255`, because the formatter works from the value and never sees your source, the same reason `1_000` prints as `1000`.',
        'It refuses to format a file containing hex.',
      ],
      correct: 1,
      explanations: [
        'The formatter has no access to the source text; it prints from the parsed tree. No numeric spelling survives it: not underscores, not exponents, not hex.',
        'Correct. Values round-trip; spellings do not (`LANGUAGE.md` §4.2). Keeping the hex spelling would need a carrier for something the value already determines.',
        'It formats normally, because hex is an ordinary integer literal by the time the printer sees it.',
      ],
    },
  ],
  'forms-and-keyword-pairing': [
    {
      q: 'What does `(stack :mode :mask)` parse as?',
      options: [
        'A `stack` form with two positional flags `:mode` and `:mask`, because a keyword can never be the value of a kvpair.',
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
        'As a positional flag, meaning as a child of a form rather than the value of a kvpair.',
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
        'Always, because they are faster to parse.',
        'When escaping would obscure the payload (shaders, regex, paths with backslashes, markup).',
        'When the string is short.',
      ],
      correct: 1,
    },
    {
      q: 'Does raw string content process `\\n` escapes?',
      options: [
        'No. Raw strings keep their bytes verbatim; `\\n` stays as a backslash and an `n`.',
        'Yes. Escapes work in both surfaces.',
        'Only inside a `(raw ...)` block.',
      ],
      correct: 0,
    },
    {
      q: 'Can block comments nest?',
      options: [
        'No. The first `|#` always closes the outermost `#|`.',
        'Only if the parser is told to.',
        'Yes. `#| ... #| inner |# ... |#` is allowed; comments nest properly.',
      ],
      correct: 0,
      explanations: [
        'Correct. `LANGUAGE.md` §2.2 is explicit: "Block comments do not nest." The lexer treats `|#` as the closer for the *outermost* open `#|`.',
        'No. The parser has no nesting mode, and block-comment lexing is fixed.',
        'This would require a counter in the lexer; SJON keeps the lexer single-pass and labeled-switch. If you need a long comment, use multiple `#| ... |#` blocks back-to-back.',
      ],
    },
  ],
  'safe-expressions': [
    {
      q: 'Can a safe expression appear as a vector element?',
      options: [
        'No. Only literals are allowed inside vectors.',
        'Only if the vector is wrapped in `(expr ...)`.',
        'Yes. A vector holds any value, so a form (expression) can sit alongside literals.',
      ],
      correct: 2,
    },
    {
      q: 'Why is `(lerp 0 :to 10 0.5)` invalid?',
      options: [
        'A labeled call is all-or-nothing, so mixing positional and labeled arguments produces `expr_mixed_args`.',
        'The numbers are out of range.',
        '`lerp` does not exist.',
      ],
      correct: 0,
    },
    {
      q: 'Why can `(vec3 1 "x" 3)` fail validation before evaluation?',
      options: [
        '`vec3` only accepts symbols.',
        'The signature is typed, so the validator catches the literal `"x"` where a number is required.',
        'Strings are illegal in expressions.',
      ],
      correct: 1,
    },
    {
      q: 'What does `(or false nil)` return?',
      options: [
        '`true`.',
        'It raises an error.',
        '`nil`, because both branches are falsy, so `or` falls through and returns the last value.',
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
        'Yes. Bindings are sequential; later names see earlier ones.',
        'No. `let` bindings are unordered.',
        'Only if wrapped in another `let`.',
      ],
      correct: 0,
    },
    {
      q: 'Can an earlier `let` binding refer to a later one?',
      options: [
        'Yes. `let` is mutually recursive.',
        'No. Earlier bindings cannot see names introduced later in the same `let`.',
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
        'When the logic needs side effects, recursion, I/O, or general computation, all of which belong in the host.',
        'Never, because SJON is Turing-complete.',
      ],
      correct: 1,
    },
  ],
  'reading-plugin-schemas': [
    {
      q: 'What does `positional: none` mean for authors?',
      options: [
        'The form takes no kvpair children.',
        'The form does not accept positional (non-key) children, only `:key value` pairs.',
        'The form must be empty.',
      ],
      correct: 1,
    },
    {
      q: 'Does `open: true` silence duplicate-key or type errors?',
      options: [
        'No. `open: true` only allows unknown keys; declared keys still enforce types and duplicate rules.',
        'Yes. Open forms accept anything.',
        'Only on discriminated forms.',
      ],
      correct: 0,
    },
    {
      q: 'Does a `.sjon` file itself choose the plugin set?',
      options: [
        'Yes. The file imports plugins explicitly.',
        'Only when a `(plugins ...)` form is present.',
        'No. The host loads plugins; the file just uses their vocabulary.',
      ],
      correct: 2,
    },
  ],
  'discriminated-and-exclusive-forms': [
    {
      q: 'On a discriminated form, why must the discriminant key appear before variant-only keys?',
      options: [
        "Until the discriminant is known, the validator can't tell which variant's keys are legal, so variant-only keys before it produce `unknown_key` with a discriminant-first hint.",
        'For readability only.',
        'It is a parser limitation.',
      ],
      correct: 0,
    },
    {
      q: 'For an `exactly-one` exclusive group, what distinguishes the "both present" diagnostic from the "neither present" one?',
      options: [
        'They share one code; only the message differs.',
        'They are distinct codes: `mutually_exclusive_keys_present` for too many, `required_one_of_missing` for too few.',
        'Only "both present" produces a diagnostic.',
      ],
      correct: 1,
    },
    {
      q: 'What does a partial multi-key exclusive bundle produce?',
      options: [
        '`exclusive_bundle_partial`, because some keys in the bundle are present and the rest are missing.',
        '`required_one_of_missing`, because partial bundles are treated as completely absent.',
        '`duplicate_key`, because the bundle counts as writing the same key twice.',
      ],
      correct: 0,
    },
    {
      q: 'What happens if an `open: true` form declares an exclusive group?',
      options: [
        'The group still fires; openness only affects unknown keys.',
        'The group does not fire, because open forms skip closed-shape cardinality sweeps.',
        'Only `at-most-one` groups fire.',
      ],
      correct: 1,
    },
    {
      q: '`:offset` declares `requires :buffer`. The document writes `(entry :binding 0 :buffer uniforms)` - the requirement, but not the dependent key. Is that an error?',
      options: [
        'No - the rule runs one way. Only writing `:offset` demands `:buffer`.',
        'Yes - the two keys must always appear together.',
        'Yes - `:buffer` is meaningless without something measured from it.',
      ],
      correct: 0,
      explanations: [
        'Correct. An absent dependent key constrains nothing, so writing only the key that others depend on is always fine.',
        'That would be a mutual dependency, which is really an exclusive-group bundle - and a plugin declaring it in both directions is rejected at load.',
        'Reasonable as design taste, but not what the rule says. The dependency points from `:offset` to `:buffer`, not back.',
      ],
    },
    {
      q: 'A form writes two keys that both require the same absent key: `(entry :binding 0 :offset 256 :size 64)`, where both require `:buffer`. How many diagnostics?',
      options: [
        'One - there is a single missing key.',
        'Two - one per key whose requirement went unsatisfied.',
        'Three - two dependents plus the missing key itself.',
      ],
      correct: 1,
      explanations: [
        'The count follows the dependent keys, not the missing ones. Contrast one key missing three requirements, which IS a single diagnostic.',
        'Correct. One per unsatisfied dependent key. The mirror rule: one key missing several requirements gets one diagnostic naming them all, because that is one problem.',
        'The absent key is not reported on its own - it is optional, so nothing requires it except the two keys that were written.',
      ],
    },
    {
      q: 'A plugin needs to express "`:strip-index-format` applies only when `:topology` is `triangle-strip`". Which of the three mechanisms?',
      options: [
        'A key dependency - `:strip-index-format` requires `:topology`.',
        'A discriminated form with a `triangle-strip` variant.',
        'An exclusive group over `:topology` and `:strip-index-format`.',
      ],
      correct: 1,
      explanations: [
        'Close, and a plugin may add this too - but a dependency only demands that `:topology` be *present*, not that it hold a particular value. The wording names a value.',
        'Correct. The rule names a specific value (`triangle-strip`), and that is the tell: values mean variants. A group counts; a dependency says "then also".',
        'A group bounds how many of a set may appear. Nothing here is about counting.',
      ],
    },
    {
      q: 'A schema summary shows `variant when [triangle-strip line-strip]` with `:strip-index-format` under it. What does `(primitive :topology triangle-list :strip-index-format uint16)` report?',
      options: [
        'Nothing - a multi-value variant applies to every member of the discriminant.',
        '`unknown_key` on `:strip-index-format` - `triangle-list` is not one of the listed values, so it selects no variant and the key has no home.',
        '`not_member` on `:topology` - only the listed values are legal discriminant values.',
      ],
      correct: 1,
      explanations: [
        'The bracket lists the values that select the variant, not the whole member set. Under any other member the variant is inactive.',
        'Correct. Selection is membership of the bracketed list: both strips select the variant, every list topology selects nothing, and a variant-only key under a non-selecting value is `unknown_key`.',
        '`triangle-list` is a perfectly good member of the topology set - the discriminant slot itself is fine. It is the variant key that has no home.',
      ],
    },
  ],
  'value-kinds-shapes': [
    {
      q: 'Is a plugin-declared value kind a new SJON syntax feature?',
      options: [
        'Yes. Each named kind adds new surface syntax.',
        'No. Value kinds are contracts on existing shapes (number, string, symbol, vector, form, union).',
        'Only when prefixed with the kind name.',
      ],
      correct: 1,
    },
    {
      q: 'When reading a named kind, what should you check first?',
      options: [
        'The error code list.',
        'The default value.',
        'The underlying shape: is the value a number, string, symbol, vector, form, or union?',
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
    {
      q: 'A slot is typed `buffer-offset: number, min 0, integer, multiple of 256`. The document writes `250.5`. Which single diagnostic fires?',
      options: [
        '`number_not_multiple` - it is not a multiple of 256.',
        '`number_not_integer` - integrality is checked before divisibility.',
        'All three, one per violated constraint.',
      ],
      correct: 1,
      explanations: [
        'It is not a multiple either, but that is not what is reported. The checks run integrality, then range, then divisibility, and only the first failure is named.',
        'Correct. Being fractional is the more basic problem - telling you to align a number that is not whole yet would be useless advice. Fix it and re-run; a second complaint may be waiting.',
        'Only the first failure is reported. Fix it and re-run to see whether another is waiting behind it.',
      ],
    },
    {
      q: 'Same slot (`min 0, integer, multiple of 256`). The document writes `-256`. Which diagnostic?',
      options: [
        '`number_below_min` - it is negative.',
        '`number_not_multiple` - a negative number cannot be a multiple.',
        'None - `-256` divides by 256 exactly.',
      ],
      correct: 0,
      explanations: [
        'Correct. `-256` is a genuine multiple of 256, so the only thing wrong with it is the sign - and range is checked before divisibility anyway.',
        'Sign is irrelevant to divisibility: `-512` is a multiple of `256`. What fails here is `:min 0`.',
        'It does divide exactly, which is why divisibility is not the complaint. But it is still below the minimum.',
      ],
    },
    {
      q: 'A plugin declares `:multiple-of -256`. What happens when the schema loads?',
      options: [
        'It is refused: the divisor must be positive.',
        'It loads and behaves as `:multiple-of 256`, since sign is irrelevant to divisibility.',
        'It loads with a warning, like a fractional divisor does.',
      ],
      correct: 0,
      explanations: [
        'Correct. The *value* may be negative - `-512` is a multiple of `256` - but the *divisor* may not. A negative divisor accepts exactly what its magnitude accepts, so nothing is lost, and JSON Schema requires `multipleOf` to be positive, so the exported schema would be one no validator will compile.',
        'That reasoning is right about the value and wrong about the divisor. It would work, which is why it was tempting; it is refused because the exported schema could not represent it.',
        'The warning case is a *fractional* divisor, which works and is only approximate. A non-positive divisor does not work at all.',
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
      q: '`2d` is a legal member of a *symbol* member set, yet `2d` is not a symbol. How does that work?',
      options: [
        'The lexer makes an exception for `d` and reads `2d` as a symbol.',
        'The schema stores the member as a `(magnitude, unit)` pair and matches the number against it, so the value stays a unit-bearing number.',
        'The validator rewrites the value into the symbol `2d` before matching.',
      ],
      correct: 1,
      explanations: [
        'There is no such exception, and there could not be a useful one: the unit alphabet is not a list of enum names.',
        'Correct. A digit-leading spelling is *accepted* in a symbol slot and never rewritten: the tree, the binary IR, and the JSON bridge all keep `{"$num": [2, "d"]}`. That is why matching is on the pair, which also makes `2.0d` and `02d` the same member.',
        "Rewriting would make a node's identity depend on the schema, which the JSON bridge and the binary encoder both forbid: `parse → validate` and `parse → binary → validate` would disagree about the tag.",
      ],
    },
    {
      q: 'Why do `:dimension 2b` and `:dimension 2` fail differently against `members 1d | 2d | 3d`?',
      options: [
        'They do not: both are `not_member`.',
        '`2b` is `not_member` (a unit-bearing number is the right shape, wrong member); `2` is `wrong_underlying` (a bare number is not a spelling at all).',
        '`2b` is `unit_not_allowed` and `2` is `not_member`.',
      ],
      correct: 1,
      explanations: [
        'The two fail one layer apart, and the codes say so, which is the point of reporting `not_member` here rather than a blanket tag mismatch.',
        'Correct. Declaring a digit-leading member is what makes the slot accept unit-bearing numbers at all; the unit is part of the identity, so `2b` gets the "which ones are allowed" report. A unitless number never enters that path.',
        '`unit_not_allowed` belongs to `(unit-shape :allowed …)` on a number-underlying kind, which is a different refinement entirely.',
      ],
    },
    {
      q: 'What does `union_no_branch_matched` tell you to reread?',
      options: [
        'The plugin manifest version.',
        'The list of alternatives the message names. The value’s shape reaches none of them, or two or more, so rewrite it to fit one.',
        'The whole document from scratch.',
      ],
      correct: 1,
    },
    {
      q: 'A slot is `union pitch | event`, where `pitch` is a symbol member set and `event` is a form head set. You write a symbol that is not in the member set. Which diagnostic?',
      options: [
        '`not_member`, listing the pitches.',
        '`union_no_branch_matched`, naming `pitch` and `event`.',
        'Both, one per alternative tried.',
      ],
      correct: 0,
      explanations: [
        'Correct. Only one of the two alternatives takes symbols at all, so the value could only ever have meant `pitch`, and the slot reports that alternative’s own reason. Write a number there instead and you get the union code, because a number reaches neither.',
        'That is the answer when the shape reaches no alternative, or reaches more than one. Here it reaches exactly one.',
        'A union emits one diagnostic for the slot, never one per alternative. Failed alternatives leave nothing behind.',
      ],
    },
    {
      q: 'When two union alternatives can both accept the same value, which one wins?',
      options: [
        'The most specific alternative, decided by shape.',
        'Whichever the plugin declared first. Order is the whole rule.',
        'Neither; an overlapping union is rejected at load.',
      ],
      correct: 1,
    },
    {
      q: 'When a union slot lists `form` as one alternative, does that mean any parenthesized construct is accepted?',
      options: [
        'Yes. Any form satisfies the slot.',
        'Only if the form is empty.',
        'No. A typed form alternative usually narrows further (e.g., a head set or a discriminated form).',
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
      q: 'A head declares `(head :name fragment :max 1)` and a form carries four `(fragment …)` children. Where does the diagnostic land, and how many do you get?',
      options: [
        'One `positional_too_many`, on the second `(fragment …)`, which is the one that crossed the ceiling.',
        'Three `positional_too_many`, one per child past the ceiling.',
        'One `positional_too_many`, on the parent form.',
      ],
      correct: 0,
      explanations: [
        'Correct. The count crosses `:max` exactly once, so the report fires on that transition, and it names the real total (4) rather than the ceiling.',
        'That would bury every other diagnostic on the form under duplicates of one fact.',
        'The parent is where a *floor* breach lands, since that one has no child to point at. A ceiling breach does.',
      ],
    },
    {
      q: 'A form declares `:open true` and a bounded `:positional` head-set. Which rules still apply?',
      options: [
        'Both counts still apply, because `:open` widens the *keyword* surface only.',
        'Neither, because `:open` turns off every end-of-form check.',
        'Only `positional_too_many`; the floor sweep is suppressed like other end-of-form sweeps.',
      ],
      correct: 0,
      explanations: [
        "Correct. Openness is about accepting unknown keywords; a form that declares `:positional <bounded-kind>` opted into its children's count.",
        'It turns off the keyword ones: required keys, the discriminant gate, exclusive groups. Positional rules like `not_head_member` already fire on open forms.',
        'That would half-enforce one declaration: max checked, min not.',
      ],
    },
    {
      q: 'The same bounded head-set kind is used on a `:positional` slot and on a `(key :type …)` slot. Where do its `:min` / `:max` counts apply?',
      options: [
        'Only at the `:positional` slot; on the keyed slot they ride along inertly.',
        'At both, because a bound is part of the kind and travels with it.',
        'Nowhere; declaring a bound on a shared kind is rejected at load.',
      ],
      correct: 0,
      explanations: [
        'Correct. A keyed slot holds one value, so `:max 1` is trivially true and `:min 1` has no set to be missing from. Inert rather than an error, so a bounded kind stays shareable.',
        'A keyed slot has no repeated population to count, so there would be nothing for the bound to mean.',
        'Rejecting reuse would make a bounded head-set kind un-shareable for no gain.',
      ],
    },
    {
      q: 'Every head in a set carries `:max 1`. Which document does that fail to reject?',
      options: [
        'A form with two `(buffer …)` children.',
        'A form with one `(buffer …)` and one `(sampler …)`. "Exactly one resource" is a claim about the set, not about any head.',
        'A form with three `(texture …)` children.',
      ],
      correct: 1,
      explanations: [
        "That one is rejected, because `buffer`'s own ceiling catches it.",
        'Correct, and raising a head\'s `:min` does not help either: `(head :name buffer :min 1)` demands a *buffer*, which is a different rule. `:min-children` / `:max-children` on the `(head-set …)` is the only spelling of "one of these, whichever".',
        "Also rejected, by `texture`'s ceiling.",
      ],
    },
    {
      q: 'Under `:min-children 1 :max-children 1` over heads each `:max 1`, a form carries two `(buffer …)` children. How many diagnostics, and which?',
      options: [
        'Two `positional_too_many`: one for the head, one for the set.',
        "One `positional_too_many`, the per-head one: it names the line to delete, and the set's claim follows from it.",
        'One `positional_too_many`, the set-level one, because the set is the outer constraint.',
      ],
      correct: 1,
      explanations: [
        'They would land on the same child, with the same code and the same path, differing only in prose, which is why the set yields to the head instead.',
        "Correct. The two levels overlap by construction on this shape, so the validator states a suppression rule: the set never reports for a child that already reported for its own head, and a head with an unmet `:min` suppresses the set's floor report.",
        'Backwards. The per-head report is the more actionable of the two, and it is the one kept.',
      ],
    },
    {
      q: 'A `positional_too_many` message reads `at most 1 positional child from [buffer | sampler | texture], found 2`. What does the bracketed set tell you?',
      options: [
        'That the set-level `:max-children` fired. The children are individually fine, and the repair is to pick one rather than de-duplicate.',
        'That the schema lists three alternatives and you used the wrong one.',
        'Nothing; the message always lists the whole head-set.',
      ],
      correct: 0,
      explanations: [
        'Correct. A per-head breach names one head; only a set-level breach names the bracket. Reading which level fired is what tells you whether the fix is "delete the duplicate" or "choose between two different children".',
        'A head outside the set is `not_head_member`, a different code entirely.',
        'A per-head message names the single head it is about, and that contrast is exactly what makes the bracket informative.',
      ],
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
        'Correct. With no `ref` named, `scalar-or-ref` expands to `union dim-value | symbol`; a bare symbol takes the reference branch.',
        'A keyword is not one of the branches; the reference branch is a bare symbol.',
      ],
    },
    {
      q: 'A `scalar-or-ref` slot names no `ref` kind, so the reference half is the plain `symbol` type. The document misspells a constant as `WORKGROUP_SIZ`. What happens at validate time?',
      options: [
        'It validates clean - any symbol satisfies the reference half.',
        'It fires `not_cross_ref` - the constant does not exist.',
        'It fires `union_no_branch_matched` - neither branch accepts it.',
      ],
      correct: 0,
      explanations: [
        'Correct. The reference half only asked for a symbol, and a misspelling is still a symbol. Nothing checked that a constant by that name exists; the mistake surfaces when the host tries to resolve it.',
        'Nothing declared the reference half as a cross-reference, so there is no target list to check against.',
        'The symbol branch accepts it, so the union matched. A string would fail this way.',
      ],
    },
    {
      q: 'The plugin instead declares the slot as `scalar-or-ref, base bone-count, ref define-ref`, where `define-ref` is a cross-reference kind. The document writes `MAX_BONE` and no `(define :name MAX_BONE ...)` exists. Which diagnostic?',
      options: [
        '`not_cross_ref` - the reference half is what failed.',
        '`union_no_branch_matched`, naming both alternatives.',
        '`wrong_underlying` - a symbol was supplied where a number belongs.',
      ],
      correct: 0,
      explanations: [
        'Correct. The two halves are disjoint by shape, so a symbol could only ever have meant the reference half. With exactly one alternative in reach, the slot reports that half’s own reason instead of the union’s list.',
        'That is what you get when the value’s shape reaches no alternative, or two or more. A symbol reaches exactly one here, so there is a branch to blame.',
        'A symbol is a legal shape here - it is the reference branch. What failed is that it names nothing.',
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
        '`not_head_member` is for a head set (a closed list of allowed head spellings); a slot that defines forms inline reports `unknown_local_form`.',
      ],
    },
    {
      q: 'A head set lists `ghost`, but no form named `ghost` is declared anywhere - not locally, not globally. The document writes `(ghost :x 1)` in that slot. How many diagnostics?',
      options: [
        'Two - `not_head_member` and `unknown_local_form`.',
        'One - `unknown_local_form`.',
        'One - `not_head_member`.',
      ],
      correct: 1,
      explanations: [
        'Two diagnostics is what an out-of-set head produces, because both steps fail. Here the head IS in the set, so the head set is satisfied.',
        'Correct. The head set admitted `ghost` (it compares spelling against its list), and the complaint came from the next step, which found no form to check the body against.',
        'A head set never reports an undeclared name - it resolves nothing. It compared `ghost` against its list, found it, and passed.',
      ],
    },
    {
      q: 'A head set names `storage-texture`, whose only `(form ...)` declaration is a slot-local of the form you are inside. Does that work?',
      options: [
        'Yes - the head set checks spelling, and the body then resolves local-first.',
        'No - head set names must be declared globally.',
        'Only if the local form is also listed in the head set twice.',
      ],
      correct: 0,
      explanations: [
        'Correct. The head set names spellings, not declarations; a local form in scope at the slot is what the body is checked against.',
        'A common misreading. It leads to declaring placeholder global forms that do nothing - the head set never consults a global catalog.',
        'Head set entries are a set of spellings; repeating one changes nothing.',
      ],
    },
  ],
  'cross-references': [
    {
      q: 'Two forms of different kinds both declare `:name same`. Is that a `duplicate_cross_ref_target`?',
      options: [
        'It depends on the schema. Per target, each name is alone in its own namespace, but one cross-reference over both forms makes them one namespace, and then it is a duplicate.',
        'Yes. A name may appear only once anywhere in the document.',
        'No, never: duplicate checking is always per target form.',
      ],
      correct: 0,
      explanations: [
        "Duplicate checking is per *namespace*, and how many namespaces exist is the schema's choice. Two single-target reference kinds give two; one kind whose `:target` lists both forms gives one.",
        'Names are scoped to the namespace a cross-reference defines, not to the document. Two unrelated forms may each declare `intro` with no interaction at all.',
        'This was the whole rule before target groups existed, and it is still the common case, but a `:target [a b]` group deliberately merges the two namespaces so the collision *is* reported.',
      ],
    },
    {
      q: 'A slot reports `duplicate_cross_ref_target` across two different forms. What does that tell you about the schema?',
      options: [
        'The two forms are in one namespace (a target group), so the schema says those names are meant to be unique across both.',
        'The plugin has a bug; duplicate checking should be per form.',
        'The two forms come from the same plugin.',
      ],
      correct: 0,
      explanations: [
        'One namespace is exactly what a target group declares. The fix is to rename one declaration, because the schema is asserting the names should not collide.',
        'It is a deliberate schema choice, not a bug. The alternative, a union of two reference kinds, keeps two namespaces and warns on each *reference* instead.',
        'Plugin origin has nothing to do with it. What matters is whether one cross-reference names both forms.',
      ],
    },
    {
      q: 'You get `union_ambiguous` on a reference. What would a target group have done with the same document?',
      options: [
        'Reported an error at the two declarations instead, and left the reference alone.',
        'Reported the same warning, because the two shapes are equivalent.',
        'Accepted it silently, since a group has no ordering.',
      ],
      correct: 0,
      explanations: [
        'The warning is about a *reference* with two readings; the group turns the same situation into an error about *declarations* that collided. Same document, different question asked.',
        'They differ precisely here. A union keeps one namespace per alternative, so the names never collide and only references are ambiguous.',
        'A group is not silent about it. It is the loudest of the two, and it complains earlier: at the declarations rather than at every use.',
      ],
    },
    {
      q: 'A union slot accepts either of two reference kinds, and a name exists in both targets. What happens?',
      options: [
        'The document is rejected with `union_no_branch_matched`.',
        'It validates silently; the last alternative wins.',
        'It validates with a `union_ambiguous` warning. First match wins, and declaration order is what picks the entity.',
      ],
      correct: 2,
    },
    {
      q: 'Why is `union_ambiguous` a warning rather than an error?',
      options: [
        'Because warnings are cheaper to compute than errors.',
        'The behaviour is defined and the document is valid. What is fragile is that another tool resolving the name its own way would silently disagree.',
        'Because the validator cannot tell whether the name is really ambiguous.',
      ],
      correct: 1,
    },
    {
      q: 'A slot is typed "a byte count or a named constant" and you write `1024`. Does that warn as ambiguous?',
      options: [
        'Yes. Any union whose alternatives overlap is ambiguous.',
        'No. The alternatives overlap by design and neither names an entity; the warning is only about two references colliding on one name.',
        'Yes, unless the plugin marks the union as ordered.',
      ],
      correct: 1,
    },
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
        'The validator runs in two passes: it builds the registry first, then checks references.',
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
        'The legal values come from the document\'s declarations, not from a closed plugin set, so the diagnostic distinguishes "no such reference" from "not in the member list".',
      ],
      correct: 2,
    },
    {
      q: 'Why is `"p0"` not the same declaration as `p0`?',
      options: [
        'Strings and symbols are different value kinds; cross-reference targets are symbols.',
        'They are the same, because strings and symbols interchange.',
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
        'Use diagnostic codes, because they map directly to repair direction.',
        'Reformat the file and re-run.',
      ],
      correct: 1,
    },
  ],
};

// `correct` is a bare number, so a question whose answer index runs past its
// own options list type-checks perfectly and renders a quiz that can never be
// answered correctly — the reader picks every option and is told each is
// wrong. Nothing caught that before. Checking at import covers every entry,
// including those in a lesson nobody rendered this build.
for (const [slug, quiz] of Object.entries(MASTERY_QUIZZES)) {
  quiz.forEach((question, i) => {
    if (!Number.isInteger(question.correct)) {
      throw new Error(`mastery quiz ${slug}[${i}]: \`correct\` is not an integer`);
    }
    if (question.correct < 0 || question.correct >= question.options.length) {
      throw new Error(
        `mastery quiz ${slug}[${i}]: \`correct\` is ${question.correct}, ` +
          `outside 0..${question.options.length - 1}`,
      );
    }
  });
}
