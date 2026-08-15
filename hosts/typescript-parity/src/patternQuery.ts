// PatternQuery — the deterministic pattern→event engine, native TypeScript
// port of `src/PatternQuery.zig`. The control flow is idiomatic recursion
// (bounded by the parser's nesting limit) rather than the Zig walker's frame
// stack, but the *algorithm* — slot tiling, fast/slow scaling, slowcat shift,
// the zero-width edge rule, and DFS child-order emission — is bit-identical,
// so the cross-host conformance corpus matches the Zig substrate.
//
// `queryDocument` is the host entry: parse → validate (pattern schema) →
// compile → query → serialize to `(haps …)` / `(diagnostics …)` text — the
// same two-shape contract the wasm hosts return.

import type { Node as AstNode } from './ast.ts';
import {
  PPC,
  type Span,
  type TimedSpan,
  TickOverflowError,
  checkedAdd,
  checkedMul,
  cycleOf,
  cycleStart,
  cycles,
  floorDiv,
  intersection,
  mulDiv,
  span,
} from './Pattern.ts';
import { assertNever } from './internal.ts';
import { parse } from './parser.ts';
import { patternPlugin } from './plugins/pattern.ts';
import { validate } from './validator.ts';

// ---------------------------------------------------------------------------
// Hap value vocabulary + compiled IR.
// ---------------------------------------------------------------------------

/** A hap's leaf payload — a subset-plus-symbol of the expression value set.
 *  `integer` holds an exact bigint (covers i64 + u64); `number` is f64. */
export type PatValue =
  | { readonly tag: 'symbol'; readonly value: string }
  | { readonly tag: 'string'; readonly value: string }
  | { readonly tag: 'keyword'; readonly value: string }
  | { readonly tag: 'number'; readonly value: number }
  | { readonly tag: 'integer'; readonly value: bigint }
  | { readonly tag: 'boolean'; readonly value: boolean }
  | { readonly tag: 'nil' };

export interface Hap {
  readonly timing: TimedSpan;
  readonly value: PatValue;
}

/** One collected query/compile diagnostic, compared on `(code, path)`. */
export interface QueryDiagnostic {
  readonly code: string;
  readonly path: readonly string[];
}

/** Compiled pattern node — the shared target both the tree front-end here and
 *  the Zig binary front-end produce. */
type CNode =
  | { readonly tag: 'silence' }
  | { readonly tag: 'pure'; readonly value: PatValue }
  | { readonly tag: 'seq'; readonly children: readonly CNode[] }
  | { readonly tag: 'stack'; readonly children: readonly CNode[] }
  | { readonly tag: 'slowcat'; readonly children: readonly CNode[] }
  | { readonly tag: 'scale'; readonly num: number; readonly den: number; readonly child: CNode };

const SILENCE: CNode = { tag: 'silence' };

// ---------------------------------------------------------------------------
// Compile — AST → CNode. Bare atoms are implicit `pure`; `[…]` vectors are
// fastcat seq; the combinator forms dispatch by head. Malformed sub-patterns
// degrade to silence (pushing `arity_mismatch` where the tree path does).
// ---------------------------------------------------------------------------

function leafValue(node: AstNode): PatValue | null {
  switch (node.tag) {
    case 'symbol':
      return { tag: 'symbol', value: node.text };
    case 'string':
      return { tag: 'string', value: node.value };
    case 'keyword':
      return { tag: 'keyword', value: node.name };
    case 'number':
      if (node.unit !== undefined) return null; // number_with_unit: not a leaf value
      return node.integerBits !== undefined
        ? { tag: 'integer', value: node.integerBits }
        : { tag: 'number', value: node.value };
    case 'boolean':
      return { tag: 'boolean', value: node.value };
    case 'nil':
      return { tag: 'nil' };
    default:
      return null; // form / vector / date / time / kvpair — not a leaf value
  }
}

function compileNode(node: AstNode, diags: QueryDiagnostic[]): CNode {
  switch (node.tag) {
    case 'form':
      return compileForm(node, diags);
    case 'vector':
      if (node.elements.length === 0) return SILENCE;
      return { tag: 'seq', children: node.elements.map((e) => compileNode(e, diags)) };
    case 'symbol':
    case 'string':
    case 'keyword':
    case 'number':
    case 'boolean':
    case 'nil': {
      const v = leafValue(node);
      return v === null ? SILENCE : { tag: 'pure', value: v };
    }
    case 'date':
    case 'time':
      return SILENCE; // unsupported as a pattern leaf this slice
    case 'kvpair':
      return SILENCE; // kvpairs only appear inside forms
    default:
      return assertNever(node);
  }
}

function positionals(children: readonly AstNode[]): AstNode[] {
  return children.filter((c) => c.tag !== 'kvpair');
}

function arityDiag(head: string): QueryDiagnostic {
  return { code: 'arity_mismatch', path: [head] };
}

function compileForm(node: AstNode & { tag: 'form' }, diags: QueryDiagnostic[]): CNode {
  const head = node.head;
  const pos = positionals(node.children);

  if (head === 'silence') return SILENCE;

  if (head === 'pure') {
    if (pos.length !== 1) {
      diags.push(arityDiag(head));
      return SILENCE;
    }
    const v = leafValue(pos[0]!);
    return v === null ? SILENCE : { tag: 'pure', value: v };
  }

  if (head === 'fast' || head === 'slow') {
    if (pos.length !== 2) {
      diags.push(arityDiag(head));
      return SILENCE;
    }
    const factorNode = pos[0]!;
    if (
      factorNode.tag !== 'number' ||
      factorNode.integerBits === undefined ||
      factorNode.unit !== undefined ||
      factorNode.integerBits <= 0n
    ) {
      return SILENCE; // non-integer / non-positive factor
    }
    const factor = Number(factorNode.integerBits);
    const child = compileNode(pos[1]!, diags);
    return head === 'fast'
      ? { tag: 'scale', num: factor, den: 1, child }
      : { tag: 'scale', num: 1, den: factor, child };
  }

  if (head === 'stack') {
    if (pos.length === 0) return SILENCE;
    return { tag: 'stack', children: pos.map((c) => compileNode(c, diags)) };
  }

  if (head === 'euclid') {
    if (pos.length !== 3) {
      diags.push(arityDiag(head));
      return SILENCE;
    }
    const nNode = pos[0]!;
    const kNode = pos[1]!;
    if (
      nNode.tag !== 'number' ||
      nNode.integerBits === undefined ||
      nNode.unit !== undefined ||
      kNode.tag !== 'number' ||
      kNode.integerBits === undefined ||
      kNode.unit !== undefined
    ) {
      return SILENCE; // non-integer pulses / steps
    }
    const nBits = nNode.integerBits;
    const kBits = kNode.integerBits;
    // Out-of-domain (k < 1, n > k) degrades to silence; n < 1 IS silence —
    // the empty rhythm. Mirrors the Zig substrate's compileEuclid gate.
    if (kBits < 1n || nBits < 1n || nBits > kBits) return SILENCE;
    const child = compileNode(pos[2]!, diags);
    return {
      tag: 'seq',
      children: bjorklund(Number(nBits), Number(kBits)).map((on) => (on ? child : SILENCE)),
    };
  }

  if (head === 'slowcat' || head === 'cat') {
    if (pos.length === 0) return SILENCE;
    return { tag: 'slowcat', children: pos.map((c) => compileNode(c, diags)) };
  }

  return SILENCE; // unknown head — the validator already flagged it
}

// Bjorklund's algorithm: distribute n pulses over k steps as evenly as
// possible (Toussaint's Euclidean rhythms) — a k-slot onset bitmap, always
// starting on a pulse: E(3,8) = x..x..x., E(5,8) = x.xx.xx. Iterative
// sequence pairing: both sides stay uniform, so each is one
// (pattern, count) pair and a round is a single concatenation. Mirrors the
// Zig substrate's `bjorklund`. Precondition: 1 <= n <= k.
function bjorklund(n: number, k: number): boolean[] {
  let patA: boolean[] = [true];
  let patB: boolean[] = [false];
  let countA = n;
  let countB = k - n;
  while (countB > 1) {
    const pairs = Math.min(countA, countB);
    const leftoverA = countA - pairs;
    const oldA = patA;
    patA = patA.concat(patB);
    if (leftoverA > 0) {
      // b exhausted — the surplus a's (old pattern) become the remainder.
      patB = oldA;
      countB = leftoverA;
    } else {
      // a exhausted (or equal) — the surplus b's stay the remainder.
      countB -= pairs;
    }
    countA = pairs;
  }
  const out: boolean[] = [];
  for (let i = 0; i < countA; i++) out.push(...patA);
  for (let i = 0; i < countB; i++) out.push(...patB);
  return out;
}

// ---------------------------------------------------------------------------
// Query — the engine. Combinators map time down (child query span) and remap
// haps back up. `scale` localizes a forward-map overflow to a
// `pattern_tick_overflow` diagnostic; seq / slowcat overflow stays fatal
// (matching the Zig substrate).
// ---------------------------------------------------------------------------

interface Affine {
  readonly inOff: number;
  readonly num: number;
  readonly den: number;
  readonly outOff: number;
}

function applyAffine(s: Span, a: Affine): Span {
  const map = (t: number): number =>
    checkedAdd(mulDiv(checkedAdd(t, -a.inOff), a.num, a.den), a.outOff);
  return span(map(s.begin), map(s.end));
}

function remapHap(h: Hap, a: Affine): Hap {
  return {
    timing: {
      whole: h.timing.whole === null ? null : applyAffine(h.timing.whole, a),
      part: applyAffine(h.timing.part, a),
    },
    value: h.value,
  };
}

function queryNode(node: CNode, window: Span, diags: QueryDiagnostic[]): Hap[] {
  switch (node.tag) {
    case 'silence':
      return [];
    case 'pure': {
      const out: Hap[] = [];
      for (const piece of cycles(window)) {
        const wholeBegin = cycleStart(piece.begin);
        const whole: Span = { begin: wholeBegin, end: checkedAdd(wholeBegin, PPC) };
        const part = intersection(whole, piece);
        if (part === null) continue;
        out.push({ timing: { whole, part }, value: node.value });
      }
      return out;
    }
    case 'seq':
      return querySeq(node.children, window, diags);
    case 'stack': {
      const out: Hap[] = [];
      for (const child of node.children) out.push(...queryNode(child, window, diags));
      return out;
    }
    case 'slowcat':
      return querySlowcat(node.children, window, diags);
    case 'scale':
      return queryScale(node, window, diags);
    default:
      return assertNever(node);
  }
}

function querySeq(children: readonly CNode[], window: Span, diags: QueryDiagnostic[]): Hap[] {
  const n = children.length;
  const slotWidth = Math.floor(PPC / n);
  const out: Hap[] = [];
  for (const piece of cycles(window)) {
    const cstart = cycleStart(piece.begin);
    for (let i = 0; i < n; i++) {
      const slotBegin = checkedAdd(cstart, i * slotWidth);
      // Last slot absorbs the remainder so slots tile the cycle with no gap.
      const slotEnd = i === n - 1 ? checkedAdd(cstart, PPC) : slotBegin + slotWidth;
      const slot: Span = { begin: slotBegin, end: slotEnd };
      const overlap = intersection(piece, slot);
      if (overlap === null) continue;
      // Forward (world → child-local): local = cstart + (world - slotBegin) * n.
      const inner = span(
        checkedAdd(cstart, checkedMul(overlap.begin - slotBegin, n)),
        checkedAdd(cstart, checkedMul(overlap.end - slotBegin, n)),
      );
      // Back (child-local → world): world = slotBegin + (local - cstart) / n.
      const back: Affine = { inOff: cstart, num: 1, den: n, outOff: slotBegin };
      for (const h of queryNode(children[i]!, inner, diags)) {
        const mapped = remapHap(h, back);
        const clipped = intersection(mapped.timing.part, slot);
        if (clipped === null) continue;
        out.push({ timing: { whole: mapped.timing.whole, part: clipped }, value: mapped.value });
      }
    }
  }
  return out;
}

function querySlowcat(children: readonly CNode[], window: Span, diags: QueryDiagnostic[]): Hap[] {
  const n = children.length;
  const out: Hap[] = [];
  for (const piece of cycles(window)) {
    const c = cycleOf(piece.begin);
    const localCycle = floorDiv(c, n);
    const i = c - n * localCycle; // positive modulo, in [0, n)
    const delta = checkedMul(c - localCycle, PPC);
    const childSpan = span(checkedAdd(piece.begin, -delta), checkedAdd(piece.end, -delta));
    const back: Affine = { inOff: 0, num: 1, den: 1, outOff: delta };
    for (const h of queryNode(children[i]!, childSpan, diags)) {
      out.push(remapHap(h, back));
    }
  }
  return out;
}

function queryScale(node: CNode & { tag: 'scale' }, window: Span, diags: QueryDiagnostic[]): Hap[] {
  let childSpan: Span;
  try {
    childSpan = span(
      mulDiv(window.begin, node.num, node.den),
      mulDiv(window.end, node.num, node.den),
    );
  } catch (err) {
    if (err instanceof TickOverflowError) {
      // Localize the window-expansion overflow; contribute no haps.
      diags.push({ code: 'pattern_tick_overflow', path: [node.num > node.den ? 'fast' : 'slow'] });
      return [];
    }
    throw err;
  }
  // Back map by den/num (swapped). Overflow here is fatal, matching Zig.
  const back: Affine = { inOff: 0, num: node.den, den: node.num, outOff: 0 };
  return queryNode(node.child, childSpan, diags).map((h) => remapHap(h, back));
}

// ---------------------------------------------------------------------------
// Serialization — hand-rolled `(haps …)` / `(diagnostics …)` text, matching
// the Zig writer byte-for-byte (the conformance comparison parses both, but
// keeping the text identical keeps the corpus authoring shared).
// ---------------------------------------------------------------------------

function appendSpan(s: Span): string {
  return `[${s.begin} ${s.end}]`;
}

function appendNumber(x: number): string {
  if (Number.isNaN(x)) return 'nan';
  if (!Number.isFinite(x)) return x > 0 ? 'inf' : '-inf';
  const s = String(x);
  // Force a float re-parse for integral values so `.number` survives.
  return /[.eE]/.test(s) ? s : `${s}.0`;
}

function appendString(s: string): string {
  let out = '"';
  for (const ch of s) {
    if (ch === '"') out += '\\"';
    else if (ch === '\\') out += '\\\\';
    else if (ch === '\n') out += '\\n';
    else if (ch === '\r') out += '\\r';
    else if (ch === '\t') out += '\\t';
    else out += ch;
  }
  return `${out}"`;
}

function appendValue(v: PatValue): string {
  switch (v.tag) {
    case 'symbol':
      return v.value;
    case 'string':
      return appendString(v.value);
    case 'keyword':
      return `:${v.value}`;
    case 'number':
      return appendNumber(v.value);
    case 'integer':
      return v.value.toString();
    case 'boolean':
      return v.value ? 'true' : 'false';
    case 'nil':
      return 'nil';
    default:
      return assertNever(v);
  }
}

export function serializeHaps(haps: readonly Hap[]): string {
  let out = '(haps';
  for (const h of haps) {
    out += ` (hap :part ${appendSpan(h.timing.part)}`;
    if (h.timing.whole === null) {
      out += ' :whole nil';
    } else if (
      h.timing.whole.begin !== h.timing.part.begin ||
      h.timing.whole.end !== h.timing.part.end
    ) {
      out += ` :whole ${appendSpan(h.timing.whole)}`;
    }
    out += ` ${appendValue(h.value)})`;
  }
  return `${out})`;
}

export function serializeDiagnostics(diags: readonly QueryDiagnostic[]): string {
  let out = '(diagnostics';
  for (const d of diags) {
    out += ` (diagnostic :code ${d.code} :path [${d.path.join(' ')}])`;
  }
  return `${out})`;
}

function resultToText(haps: readonly Hap[], diags: readonly QueryDiagnostic[]): string {
  return diags.length > 0 ? serializeDiagnostics(diags) : serializeHaps(haps);
}

// ---------------------------------------------------------------------------
// Host entry — parse → validate (pattern schema) → compile → query → text.
// ---------------------------------------------------------------------------

/** Query a pattern document over the half-open tick window `[begin, end)`
 *  with RNG `seed` (reserved; the MVP vocabulary is seed-independent).
 *  Returns the `(haps …)` / `(diagnostics …)` text. */
export function queryDocument(source: string, begin: number, end: number, seed: number): string {
  void seed;
  if (begin > end) throw new Error(`invalid query window: begin ${begin} > end ${end}`);
  const roots = parse(source);
  if (roots.length !== 1)
    throw new Error(`pattern document must have exactly one root, got ${roots.length}`);

  const diags: QueryDiagnostic[] = [];
  // Validate against the pattern schema (parity with the parse→validate→query
  // pipeline); clean for well-formed patterns, so the output is the query's.
  for (const d of validate({ plugins: [patternPlugin] }, roots)) {
    diags.push({ code: d.code, path: d.path });
  }
  const node = compileNode(roots[0]!, diags);
  const haps = queryNode(node, span(begin, end), diags);
  return resultToText(haps, diags);
}
