// SJON parser — minimal but correct over the corpus subset.
//
// Tokenises and parses in one combined pass since the language is
// LL(1). Produces an array of root nodes; each node is a tree built
// with constructor objects from `ast.ts`. No comment retention,
// no spans-on-trivia.
//
// STRUCTURAL RECOVERY. `Parser.zig`'s contract — "trees always exist
// after parse (possibly partial); collection over abort"
// (docs/LANGUAGE.md §4.3) — is honoured here for the three *structural* deviations,
// each emitting an `unspecified` diagnostic and continuing:
//
//   * a form left open at end of input   (closed at `source.length`)
//   * a vector left open at end of input (ditto)
//   * a close delimiter at top level     (skipped)
//
// This is not full parity with `Parser.zig`, which recovers from every
// deviation. The remaining sites — an unterminated string, an invalid
// number literal, a close delimiter that mismatches its opener — still
// throw a `ParseError`. They are listed in
// `test/parse-recovery.test.ts`, which pins both halves so the split
// stays deliberate rather than drifting.
//
// Recovery needs the semantic path a diagnostic is attributed to, which
// `Parser.zig` snapshots off its frame stack (`buildPath`). Recursive
// descent has no such stack, so `frames` mirrors one for attribution
// only — pushed on entry to a form/vector, popped on exit. See
// `buildPath` below for the walk it reproduces.
//
// Integer literals that exceed the i64/u64 range are a fourth
// collection-over-abort site: the parser falls back to
// `Number.parseFloat` storage and accumulates a
// `number_overflow_exact_integer` diagnostic. This mirrors
// `Parser.zig`'s overflow path so consumers can keep parsing past a
// lossy integer literal.

import type { Node, FormNode, Span } from './ast.ts';
import type { Diagnostic } from './diagnostics.ts';

export function parse(source: string, diagOut?: Diagnostic[]): readonly Node[] {
  const p = new Parser(source);
  const out: Node[] = [];
  p.skipWhitespace();
  while (!p.atEnd()) {
    // A close delimiter with no opener belongs to no form, so it is
    // reported with an empty path and skipped. `parseNode` would send
    // it to `parseSymbolOrLiteral`, which throws on the empty
    // identifier; recovering here keeps every *following* root — the
    // half of the contract a bare "did it throw?" check misses.
    const c = p.peek();
    if (c === ')' || c === ']') {
      p.recordUnexpectedClose();
      p.skipWhitespace();
      continue;
    }
    out.push(p.parseNode());
    p.skipWhitespace();
  }
  if (diagOut) diagOut.push(...p.diagnostics);
  return out;
}

/** How a child node is named within its parent: a kvpair key, or a
 *  positional/element ordinal rendered as a decimal string. */
interface PathStep {
  step: string;
  viaKvpair: boolean;
}

const NO_STEP: PathStep = { step: '', viaKvpair: false };

/** One entry of the attribution stack mirroring `Parser.zig`'s `Frame`.
 *  Carries only what `buildPath` reads — no children, no spans. */
interface PathFrame {
  kind: 'form' | 'vector';
  /** Form head; `''` for vectors and for synthetic empty-head forms. */
  head: string;
  /** The step naming this frame within its parent: a kvpair key, or a
   *  positional/element ordinal rendered as a decimal string. */
  parentStep: string;
  /** True when this frame is the value of a kvpair, in which case the
   *  key *and* the head both appear in the path. */
  parentViaKvpair: boolean;
}

class Parser {
  private readonly src: string;
  private pos: number = 0;
  readonly diagnostics: Diagnostic[] = [];
  /** Enclosing forms/vectors, innermost last. Attribution only. */
  private readonly frames: PathFrame[] = [];
  /** Set by a parent immediately before descending into a child; taken
   *  by `parseNode`, which hands it to the child's frame push. Mirrors
   *  `computeChildStep`. Read through `takePendingStep` only — a step
   *  left behind by a non-container child (a number, a symbol) would
   *  otherwise be picked up by the next form pushed, prefixing its path
   *  with a sibling's key. */
  private pendingStep: PathStep = NO_STEP;

  constructor(src: string) {
    this.src = src;
  }

  peek(): string | undefined {
    return this.src[this.pos];
  }

  /** Snapshot the semantic path of the currently-open frames. Mirrors
   *  `Parser.zig:buildPath` with `in_progress = false`: per frame, a
   *  kvpair key (when reached as a kvpair value) followed by the form
   *  head; vectors contribute their parent step alone. Zig skips its
   *  root frame — `frames` here holds no root, so the walk is total. */
  private buildPath(): string[] {
    const out: string[] = [];
    for (const f of this.frames) {
      if (f.parentViaKvpair) {
        if (f.parentStep.length > 0) out.push(f.parentStep);
        if (f.kind === 'form' && f.head.length > 0) out.push(f.head);
      } else {
        const step = f.kind === 'form' && f.head.length > 0 ? f.head : f.parentStep;
        if (step.length > 0) out.push(step);
      }
    }
    return out;
  }

  /** Emit a parser diagnostic against the open frames. Parser syntax
   *  diagnostics all carry `unspecified`, per `Parser.zig`. */
  private recordSyntax(message: string, start: number, end: number): void {
    this.diagnostics.push({
      code: 'unspecified',
      message,
      path: this.buildPath(),
      span: { start, end },
      severity: 'err',
    });
  }

  /** Report and consume a close delimiter that closes nothing. */
  recordUnexpectedClose(): void {
    this.recordSyntax('unexpected close delimiter at top level', this.pos, this.pos + 1);
    this.pos++;
  }

  /** Read and clear the step the parent left for this child. */
  private takePendingStep(): PathStep {
    const s = this.pendingStep;
    this.pendingStep = NO_STEP;
    return s;
  }

  /** Push the frame a child node opens. */
  private pushFrame(kind: 'form' | 'vector', head: string, parent: PathStep): void {
    this.frames.push({
      kind,
      head,
      parentStep: parent.step,
      parentViaKvpair: parent.viaKvpair,
    });
  }

  atEnd(): boolean {
    return this.pos >= this.src.length;
  }

  /** Consume whitespace and ; line comments. Block comments and
   *  significant trivia are out of scope for this minimal port. */
  skipWhitespace(): void {
    while (!this.atEnd()) {
      const c = this.src[this.pos];
      if (c === ' ' || c === '\t' || c === '\n' || c === '\r' || c === ',') {
        this.pos++;
      } else if (c === ';') {
        while (!this.atEnd() && this.src[this.pos] !== '\n') this.pos++;
      } else {
        break;
      }
    }
  }

  parseNode(): Node {
    this.skipWhitespace();
    // Taken unconditionally: only forms and vectors open a frame, so a
    // step left for any other node kind must be discarded here rather
    // than surviving to the next container.
    const parentStep = this.takePendingStep();
    if (this.atEnd()) {
      throw new ParseError('unexpected end of input', this.pos);
    }
    const c = this.src[this.pos]!;
    if (c === '(') return this.parseForm(parentStep);
    if (c === '[') return this.parseVector(parentStep);
    if (c === ':') return this.parseKeyword();
    if (c === '"') return this.parseString();
    if (c === '-' || (c >= '0' && c <= '9')) return this.parseNumber();
    return this.parseSymbolOrLiteral();
  }

  parseForm(parentStep: PathStep): FormNode {
    const start = this.pos;
    this.expect('(');
    this.skipWhitespace();

    // Parse head — symbol, possibly qualified `<ns>/<name>`.
    const headStart = this.pos;
    const headRaw = this.consumeBareIdentifier();
    const headEnd = this.pos;
    let head = headRaw;
    let namespace: string | null = null;
    const slash = headRaw.indexOf('/');
    if (slash >= 0) {
      namespace = headRaw.slice(0, slash);
      head = headRaw.slice(slash + 1);
    }
    const headSpan: Span = { start: headStart, end: headEnd };
    this.pushFrame('form', head, parentStep);

    // Parse children (greedy `:k v` pairing).
    const children: Node[] = [];
    /** Positional (non-kvpair, non-keyword) children so far — the step
     *  a positional child is named by. Mirrors `computeChildStep`. */
    let positionals = 0;
    while (true) {
      this.skipWhitespace();
      if (this.atEnd()) {
        // Recovery: close the form at end of input. `Parser.zig`'s
        // `closeUnclosedFrames` emits before popping, so the path
        // still names this form — emit while the frame is pushed. In
        // recursive descent the innermost open frame reaches this
        // first, which reproduces Zig's innermost-first ordering.
        this.recordSyntax('unclosed delimiter at end of input', this.pos, this.pos);
        break;
      }
      if (this.src[this.pos] === ')') {
        this.pos++;
        break;
      }
      this.pendingStep = { step: String(positionals), viaKvpair: false };
      const ch = this.parseNode();
      if (ch.tag === 'keyword') {
        // Greedy pairing — consume the next non-keyword node as value.
        // If the next node is also a keyword, this :k becomes a
        // positional keyword flag (no v0.1 corpus case exercises this,
        // but we mirror the rule for fidelity).
        this.skipWhitespace();
        if (!this.atEnd() && this.src[this.pos] !== ')' && this.src[this.pos] !== ':') {
          this.pendingStep = { step: ch.name, viaKvpair: true };
          const value = this.parseNode();
          children.push({
            tag: 'kvpair',
            key: ch.name,
            keySpan: ch.span,
            value,
            span: { start: ch.span.start, end: this.pos },
          });
        } else {
          children.push(ch);
        }
      } else {
        children.push(ch);
        positionals++;
      }
    }
    this.frames.pop();

    const span: Span = { start, end: this.pos };
    return {
      tag: 'form',
      head,
      namespace,
      headSpan,
      children,
      span,
    };
  }

  parseVector(parentStep: PathStep): Node {
    const start = this.pos;
    this.expect('[');
    this.pushFrame('vector', '', parentStep);
    const elements: Node[] = [];
    while (true) {
      this.skipWhitespace();
      if (this.atEnd()) {
        // Recovery, as in `parseForm`. A vector contributes only its
        // parent step to the path — it has no head of its own.
        this.recordSyntax('unclosed delimiter at end of input', this.pos, this.pos);
        break;
      }
      if (this.src[this.pos] === ']') {
        this.pos++;
        break;
      }
      this.pendingStep = { step: String(elements.length), viaKvpair: false };
      elements.push(this.parseNode());
    }
    this.frames.pop();
    return { tag: 'vector', elements, span: { start, end: this.pos } };
  }

  parseKeyword(): Node {
    const start = this.pos;
    this.expect(':');
    const name = this.consumeBareIdentifier();
    return { tag: 'keyword', name, span: { start, end: this.pos } };
  }

  parseString(): Node {
    const start = this.pos;
    this.expect('"');
    let out = '';
    while (!this.atEnd() && this.src[this.pos] !== '"') {
      let c = this.src[this.pos]!;
      if (c === '\\' && this.pos + 1 < this.src.length) {
        const next = this.src[this.pos + 1]!;
        this.pos += 2;
        switch (next) {
          case 'n':
            out += '\n';
            break;
          case 't':
            out += '\t';
            break;
          case 'r':
            out += '\r';
            break;
          case '"':
            out += '"';
            break;
          case '\\':
            out += '\\';
            break;
          default:
            out += next;
            break;
        }
        continue;
      }
      out += c;
      this.pos++;
    }
    if (this.atEnd()) throw new ParseError('unterminated string', this.pos);
    this.pos++; // closing "
    return { tag: 'string', value: out, span: { start, end: this.pos } };
  }

  parseNumber(): Node {
    const start = this.pos;
    // Date literal lookahead — mirrors the Zig lexer's date path. If
    // exactly four ASCII digits, then `-DD-DD` follow, emit a Tag.date
    // node; out-of-range components become date_invalid_* diagnostics.
    if (this.matchDateLookahead(start)) {
      return this.parseDateLiteral(start);
    }
    // Time literal lookahead — mirrors the Zig lexer's time path. If
    // exactly two ASCII digits precede `:`, the 6- (or 10-) char tail
    // is matched and a Tag.time node is emitted. Out-of-range
    // components become time_invalid_* diagnostics.
    const timeLen = this.matchTimeLookahead(start);
    if (timeLen !== null) {
      return this.parseTimeLiteral(start, timeLen);
    }
    if (this.src[this.pos] === '-') this.pos++;
    while (
      !this.atEnd() &&
      ((this.src[this.pos]! >= '0' && this.src[this.pos]! <= '9') ||
        this.src[this.pos] === '.' ||
        this.src[this.pos] === 'e' ||
        this.src[this.pos] === 'E' ||
        this.src[this.pos] === '+' ||
        this.src[this.pos] === '-')
    ) {
      this.pos++;
    }
    const numericEnd = this.pos;
    // Unit suffix: letters or `%` attached without whitespace. The Zig
    // lexer has finer-grained rules for `e`/`E` disambiguation against
    // exponents (see `Lexer.zig` `number_unit`); the corpus inputs
    // exercised here (`5deg`, `5ms`) sit clear of that overlap.
    let unit: string | undefined;
    if (!this.atEnd()) {
      const c = this.src[this.pos]!;
      if (c === '%' || (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z')) {
        const unitStart = this.pos;
        while (!this.atEnd()) {
          const u = this.src[this.pos]!;
          if (
            u === '(' ||
            u === ')' ||
            u === '[' ||
            u === ']' ||
            u === ' ' ||
            u === '\t' ||
            u === '\n' ||
            u === '\r' ||
            u === ',' ||
            u === ';' ||
            u === '"' ||
            u === ':'
          )
            break;
          this.pos++;
        }
        unit = this.src.slice(unitStart, this.pos);
      }
    }
    const text = this.src.slice(start, numericEnd);
    const value = Number.parseFloat(text);
    if (Number.isNaN(value)) {
      throw new ParseError(`invalid number literal '${text}'`, start);
    }
    // Pure-integer lexeme outside the safe i64/u64 range: emit the
    // parity diagnostic so the TS host's diagnostic stream matches
    // the Zig parser's. We still ship a NumberNode with the lossy
    // f64 so downstream validation keeps walking.
    let integerBits: bigint | undefined;
    if (unit === undefined && /^-?\d+$/.test(text)) {
      try {
        const big = BigInt(text);
        const positive = big >= 0n;
        const fitsU64 = positive && big < 1n << 64n;
        const fitsI64 = !positive && big >= -(1n << 63n);
        if (!fitsU64 && !fitsI64) {
          this.diagnostics.push({
            code: 'number_overflow_exact_integer',
            message: 'integer literal exceeds u64 range; storing as approximate f64',
            path: [],
            span: { start, end: numericEnd },
            severity: 'err',
          });
        } else {
          // Retain the exact magnitude so the validator's `:numeric`
          // bound check can compare in integer space against an
          // integer-tag bound. f64 alone loses the off-by-one above
          // 2^53; the bigint preserves it.
          integerBits = big;
        }
      } catch {
        // BigInt parse should not fail given the regex match; treat as
        // a no-op fallback.
      }
    }
    const span: Span = { start, end: this.pos };
    if (unit !== undefined) return { tag: 'number', value, unit, span };
    if (integerBits !== undefined) return { tag: 'number', value, integerBits, span };
    return { tag: 'number', value, span };
  }

  /** Returns true iff the input starting at `start` matches the strict
   *  10-char date shape `YYYY-MM-DD` (four digits, hyphen, two digits,
   *  hyphen, two digits). Mirrors `Lexer.matchDateTail` in Zig. */
  matchDateLookahead(start: number): boolean {
    if (start + 10 > this.src.length) return false;
    for (const i of [0, 1, 2, 3, 5, 6, 8, 9] as const) {
      const c = this.src[start + i]!;
      if (c < '0' || c > '9') return false;
    }
    if (this.src[start + 4] !== '-') return false;
    if (this.src[start + 7] !== '-') return false;
    return true;
  }

  /** Materialize a date literal, given the lexer's lookahead already
   *  matched. Out-of-range components emit `date_invalid_*` diagnostics
   *  and a defaulted `0001-01-01` node, mirroring the Zig parser. */
  parseDateLiteral(start: number): Node {
    const yearStr = this.src.slice(start, start + 4);
    const monthStr = this.src.slice(start + 5, start + 7);
    const dayStr = this.src.slice(start + 8, start + 10);
    this.pos = start + 10;
    const span: Span = { start, end: this.pos };
    const year = Number.parseInt(yearStr, 10);
    const month = Number.parseInt(monthStr, 10);
    const day = Number.parseInt(dayStr, 10);
    if (year < 1 || year > 9999) {
      this.diagnostics.push({
        code: 'date_invalid_year',
        message: 'date year out of range (1..9999)',
        path: [],
        span,
        severity: 'err',
      });
      return { tag: 'date', year: 1, month: 1, day: 1, span };
    }
    if (month < 1 || month > 12) {
      this.diagnostics.push({
        code: 'date_invalid_month',
        message: 'date month out of range (1..12)',
        path: [],
        span,
        severity: 'err',
      });
      return { tag: 'date', year: 1, month: 1, day: 1, span };
    }
    if (day < 1 || day > daysInMonth(year, month)) {
      this.diagnostics.push({
        code: 'date_invalid_day',
        message: 'date day out of range for the given year and month',
        path: [],
        span,
        severity: 'err',
      });
      return { tag: 'date', year: 1, month: 1, day: 1, span };
    }
    return { tag: 'date', year, month, day, span };
  }

  /** Returns the consumed length (8 or 12) iff the input starting at
   *  `start` matches one of the strict clock-time shapes, or `null`
   *  on miss. Mirrors `Lexer.matchTimeTail` in Zig — the fractional
   *  `.fff` is all-or-nothing: a `.` followed by anything other than
   *  exactly 3 digits falls back to the 8-char match. */
  matchTimeLookahead(start: number): 8 | 12 | null {
    if (start + 8 > this.src.length) return null;
    for (const i of [0, 1, 3, 4, 6, 7] as const) {
      const c = this.src[start + i]!;
      if (c < '0' || c > '9') return null;
    }
    if (this.src[start + 2] !== ':') return null;
    if (this.src[start + 5] !== ':') return null;
    // Optional `.fff` — all-or-nothing.
    if (start + 12 <= this.src.length && this.src[start + 8] === '.') {
      let ok = true;
      for (const i of [9, 10, 11] as const) {
        const c = this.src[start + i]!;
        if (c < '0' || c > '9') {
          ok = false;
          break;
        }
      }
      if (ok) return 12;
    }
    return 8;
  }

  /** Materialize a time literal, given the lexer's lookahead already
   *  matched `len` chars (8 or 12). Out-of-range components emit
   *  `time_invalid_*` diagnostics and a defaulted `00:00:00.000` node,
   *  mirroring the Zig parser. Millisecond range is enforced at the
   *  lexer level (exactly 3 digits ⇒ 0..999), so no fourth diagnostic
   *  is needed. */
  parseTimeLiteral(start: number, len: 8 | 12): Node {
    const hourStr = this.src.slice(start, start + 2);
    const minuteStr = this.src.slice(start + 3, start + 5);
    const secondStr = this.src.slice(start + 6, start + 8);
    this.pos = start + len;
    const span: Span = { start, end: this.pos };
    const hour = Number.parseInt(hourStr, 10);
    const minute = Number.parseInt(minuteStr, 10);
    const second = Number.parseInt(secondStr, 10);
    const millisecond = len === 12 ? Number.parseInt(this.src.slice(start + 9, start + 12), 10) : 0;
    if (hour > 23) {
      this.diagnostics.push({
        code: 'time_invalid_hour',
        message: 'time hour out of range (0..23)',
        path: [],
        span,
        severity: 'err',
      });
      return { tag: 'time', hour: 0, minute: 0, second: 0, millisecond: 0, span };
    }
    if (minute > 59) {
      this.diagnostics.push({
        code: 'time_invalid_minute',
        message: 'time minute out of range (0..59)',
        path: [],
        span,
        severity: 'err',
      });
      return { tag: 'time', hour: 0, minute: 0, second: 0, millisecond: 0, span };
    }
    if (second > 59) {
      this.diagnostics.push({
        code: 'time_invalid_second',
        message: 'time second out of range (0..59)',
        path: [],
        span,
        severity: 'err',
      });
      return { tag: 'time', hour: 0, minute: 0, second: 0, millisecond: 0, span };
    }
    return { tag: 'time', hour, minute, second, millisecond, span };
  }

  parseSymbolOrLiteral(): Node {
    const start = this.pos;
    const text = this.consumeBareIdentifier();
    if (text === 'true' || text === 'false') {
      return {
        tag: 'boolean',
        value: text === 'true',
        span: { start, end: this.pos },
      };
    }
    if (text === 'nil') {
      return { tag: 'nil', span: { start, end: this.pos } };
    }
    return { tag: 'symbol', text, span: { start, end: this.pos } };
  }

  /** Consume a bare identifier — letters, digits, dashes, underscores,
   *  slashes (for `ns/name`), and the operator characters used by the
   *  core expression vocabulary. Stops at any structural character. */
  consumeBareIdentifier(): string {
    const start = this.pos;
    while (!this.atEnd()) {
      const c = this.src[this.pos]!;
      if (
        c === '(' ||
        c === ')' ||
        c === '[' ||
        c === ']' ||
        c === ' ' ||
        c === '\t' ||
        c === '\n' ||
        c === '\r' ||
        c === ',' ||
        c === ';' ||
        c === '"' ||
        c === ':'
      ) {
        break;
      }
      this.pos++;
    }
    if (this.pos === start) {
      throw new ParseError('expected an identifier', start);
    }
    return this.src.slice(start, this.pos);
  }

  expect(ch: string): void {
    if (this.atEnd() || this.src[this.pos] !== ch) {
      throw new ParseError(`expected '${ch}'`, this.pos);
    }
    this.pos++;
  }
}

export class ParseError extends Error {
  readonly position: number;
  constructor(message: string, position: number) {
    super(`${message} (at offset ${position})`);
    this.position = position;
  }
}

/** Days in `month` of `year` (1-based). February depends on the
 *  proleptic Gregorian leap rule (divisible by 4, except centuries
 *  not divisible by 400). Mirrors `Date.daysInMonth` in Zig. */
function daysInMonth(year: number, month: number): number {
  if (month === 2) {
    const leap = year % 4 === 0 && (year % 100 !== 0 || year % 400 === 0);
    return leap ? 29 : 28;
  }
  const table = [31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31];
  return table[month - 1]!;
}
