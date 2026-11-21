// Explicit-frame SJON parser: forms, vectors, and the one greedy pairing pass.
//
// The repository's frame-stack rule applies to this port too. There is no
// recursive descent: containers push a heap `Frame`, delimiters pop it, and a
// depth ceiling bounds the stack by data rather than by the JS call stack.
// Depth/recovery diagnostics are pinned by Task 5; this module already runs
// the same push/pop machinery so Task 5 extends behaviour instead of
// rewriting the parser.
//
// Pairing is exactly `Parser.zig`'s `handleKeywordToken` + `attach`:
//
//   * forms and the root frame hold at most one pending key;
//   * the next attached node becomes that key's value (a kvpair);
//   * another keyword, a frame close, or end of input first commits the
//     pending key as a positional keyword ("flag");
//   * vectors never set pending, so `:k :v` there is two positional keywords;
//   * the root frame unrolls a pending pair into a keyword root followed by
//     the value root, with the engine's `keyword pair at top level` error.
//
// `fields()` is a view over these children and is deliberately not involved
// here: pairing happens once, in this file.
//
// Every parser diagnostic carries `code: 'unspecified'` and `severity: 'err'`,
// because `Parser.zig`'s `emit` never overrides the Diagnostic defaults. Its
// `in_progress` boolean (false for frame-level errors) only controls whether
// `buildPath` appends the slot currently being parsed.

import { makeAtom } from './atoms.ts';
import type { ReadDiagnostic } from './diagnostics.ts';
import { Lexer, type Token } from './lexer.ts';
import type { FormNode, KeywordNode, KvpairNode, Node, Span, VectorNode } from './nodes.ts';
import { decodeRange } from './source.ts';

/** Maximum frame count, root frame included. Mirrors `Parser.MAX_PARSE_DEPTH`. */
export const MAX_PARSE_DEPTH = 1024;

/** One parse's complete output. */
export interface ParsedSource {
  readonly roots: readonly Node[];
  readonly diagnostics: readonly ReadDiagnostic[];
}

interface PendingKey {
  readonly key: string;
  readonly keySpan: Span;
}

/** A child before materialization: positional node, or deferred kvpair. */
type ChildEntry =
  | { readonly type: 'positional'; readonly node: Node }
  | {
      readonly type: 'keyword';
      readonly key: string;
      readonly keySpan: Span;
      readonly value: Node;
    };

type FrameKind =
  | { readonly kind: 'root' }
  | {
      readonly kind: 'form';
      readonly head: string;
      readonly namespace: string | null;
      readonly headSpan: Span;
      readonly openStart: number;
    }
  | { readonly kind: 'vector'; readonly openStart: number };

/**
 * One open container. The root frame is always present so attach/close logic
 * is uniform, exactly like `Parser.zig`'s `Frame`.
 */
interface Frame {
  readonly kind: FrameKind;
  /** Step naming this frame in its parent: a kvpair key or an ordinal. */
  readonly parentStep: string;
  /** True when this frame is a kvpair value (path emits key then head). */
  readonly parentViaKey: boolean;
  readonly children: ChildEntry[];
  pending: PendingKey | null;
}

interface ParserState {
  readonly bytes: Uint8Array;
  readonly lexer: Lexer;
  readonly frames: Frame[];
  readonly diagnostics: ReadDiagnostic[];
}

/** How the semantic path names one step: kvpair key, or positional index. */
interface PathStep {
  readonly step: string;
  readonly viaKey: boolean;
}

type LoopAction = 'keep-going' | 'stop';

function rootFrame(): Frame {
  return {
    kind: { kind: 'root' },
    parentStep: '',
    parentViaKey: false,
    children: [],
    pending: null,
  };
}

function topFrame(frames: readonly Frame[]): Frame {
  const frame = frames[frames.length - 1];
  if (frame === undefined) {
    throw new Error('parser frame stack underflow (internal invariant)');
  }
  return frame;
}

/**
 * Split a head on its first interior `/`, exactly `Parser.splitNamespace`:
 * a leading or trailing slash is not a separator, so `/head` and `ns/` keep
 * their whole spelling as the head and have no namespace.
 */
function splitNamespace(text: string): {
  readonly head: string;
  readonly namespace: string | null;
} {
  const slash = text.indexOf('/');
  if (slash > 0 && slash + 1 < text.length) {
    return { namespace: text.slice(0, slash), head: text.slice(slash + 1) };
  }
  return { namespace: null, head: text };
}

/** Mirror `computeChildStep` for the frame that is about to receive a child. */
function childStep(parent: Frame): PathStep {
  switch (parent.kind.kind) {
    case 'root':
      return { step: '', viaKey: false };
    case 'form': {
      if (parent.pending !== null) {
        return { step: parent.pending.key, viaKey: true };
      }
      let positional = 0;
      for (const child of parent.children) {
        if (child.type === 'positional') positional += 1;
      }
      return { step: String(positional), viaKey: false };
    }
    case 'vector':
      return { step: String(parent.children.length), viaKey: false };
  }
}

/** Mirror `buildPath`: enclosing frames, then the in-progress slot suffix. */
function buildPath(frames: readonly Frame[], inProgress: boolean): string[] {
  const path: string[] = [];

  for (let index = 1; index < frames.length; index += 1) {
    const frame = frames[index];
    if (frame === undefined) continue;
    if (frame.parentViaKey) {
      if (frame.parentStep.length > 0) path.push(frame.parentStep);
      if (frame.kind.kind === 'form' && frame.kind.head.length > 0) {
        path.push(frame.kind.head);
      }
      continue;
    }
    const step =
      frame.kind.kind === 'form'
        ? frame.kind.head.length > 0
          ? frame.kind.head
          : frame.parentStep
        : frame.parentStep;
    if (step.length > 0) path.push(step);
  }

  if (inProgress && frames.length > 1) {
    const top = topFrame(frames);
    switch (top.kind.kind) {
      case 'form': {
        if (top.pending !== null) {
          path.push(top.pending.key);
          break;
        }
        let positional = 0;
        for (const child of top.children) {
          if (child.type === 'positional') positional += 1;
        }
        path.push(String(positional));
        break;
      }
      case 'vector':
        path.push(String(top.children.length));
        break;
      case 'root':
        break;
    }
  }

  return path;
}

/**
 * Append one parser diagnostic. `inProgress` is `Parser.zig`'s flag: true
 * snapshots the slot being parsed, false reports the frame itself.
 */
function emit(
  diagnostics: ReadDiagnostic[],
  frames: readonly Frame[],
  token: Token,
  message: string,
  inProgress: boolean,
): void {
  diagnostics.push({
    code: 'unspecified',
    severity: 'err',
    message,
    span: { start: token.start, end: token.end },
    path: buildPath(frames, inProgress),
  });
}

/** Commit a pending key as a positional keyword node ("flag"). */
function flushPendingFlag(frame: Frame): void {
  const pending = frame.pending;
  if (pending === null) return;
  frame.pending = null;
  const keyword: KeywordNode = {
    tag: 'keyword',
    span: pending.keySpan,
    value: pending.key,
  };
  frame.children.push({ type: 'positional', node: keyword });
}

/** Attach a materialized node, materializing a kvpair when a key is pending. */
function attach(frames: readonly Frame[], node: Node): void {
  const top = topFrame(frames);
  const pending = top.pending;
  if (pending === null) {
    top.children.push({ type: 'positional', node });
    return;
  }
  top.pending = null;
  top.children.push({
    type: 'keyword',
    key: pending.key,
    keySpan: pending.keySpan,
    value: node,
  });
}

/** Classify one leaf token with the path of the slot it occupies. */
function makeLeaf(state: ParserState, token: Token): Node | null {
  const atom = makeAtom(state.bytes, token, buildPath(state.frames, true));
  if (atom === null) return null;
  state.diagnostics.push(...atom.diagnostics);
  return atom.node;
}

/** Materialize one non-root frame into its form or vector node. */
function finalizeFrame(frame: Frame, end: number): Node {
  switch (frame.kind.kind) {
    case 'form': {
      const children: Node[] = [];
      for (const entry of frame.children) {
        if (entry.type === 'positional') {
          children.push(entry.node);
          continue;
        }
        const kvpair: KvpairNode = {
          tag: 'kvpair',
          span: { start: entry.keySpan.start, end: entry.value.span.end },
          key: entry.key,
          keySpan: entry.keySpan,
          value: entry.value,
        };
        children.push(kvpair);
      }
      const form: FormNode = {
        tag: 'form',
        span: { start: frame.kind.openStart, end },
        head: frame.kind.head,
        namespace: frame.kind.namespace,
        headSpan: frame.kind.headSpan,
        children,
      };
      return form;
    }
    case 'vector': {
      const elements: Node[] = [];
      for (const entry of frame.children) {
        // Vectors never set pending, so a keyword entry is unreachable here.
        if (entry.type === 'positional') elements.push(entry.node);
      }
      const vector: VectorNode = {
        tag: 'vector',
        span: { start: frame.kind.openStart, end },
        elements,
      };
      return vector;
    }
    case 'root':
      throw new Error('root frame has no node (internal invariant)');
  }
}

/** Pop the root frame: unroll kvpair entries into keyword + value roots. */
function finalizeRoot(state: ParserState): Node[] {
  const root = topFrame(state.frames);
  const roots: Node[] = [];
  const frames = [root];
  for (const entry of root.children) {
    if (entry.type === 'positional') {
      roots.push(entry.node);
      continue;
    }
    emit(
      state.diagnostics,
      frames,
      { tag: 'keyword', start: entry.keySpan.start, end: entry.keySpan.end },
      'keyword pair at top level (expected inside a form)',
      false,
    );
    const keyword: KeywordNode = {
      tag: 'keyword',
      span: entry.keySpan,
      value: entry.key,
    };
    roots.push(keyword, entry.value);
  }
  return roots;
}

/** Pull the next non-comment token, as `Parser.nextSignificant` does. */
function nextSignificant(state: ParserState): Token {
  while (true) {
    const token = state.lexer.next();
    if (token.tag !== 'comment_line' && token.tag !== 'comment_block') return token;
  }
}

function handleOpenParen(state: ParserState, token: Token): LoopAction {
  if (state.frames.length >= MAX_PARSE_DEPTH) {
    emit(state.diagnostics, state.frames, token, 'nesting too deep', true);
    return 'stop';
  }
  const headToken = nextSignificant(state);
  switch (headToken.tag) {
    case 'symbol':
    case 'true_lit':
    case 'false_lit':
    case 'nil_lit': {
      const split = splitNamespace(decodeRange(state.bytes, headToken.start, headToken.end));
      const step = childStep(topFrame(state.frames));
      state.frames.push({
        kind: {
          kind: 'form',
          head: split.head,
          namespace: split.namespace,
          headSpan: { start: headToken.start, end: headToken.end },
          openStart: token.start,
        },
        parentStep: step.step,
        parentViaKey: step.viaKey,
        children: [],
        pending: null,
      });
      return 'keep-going';
    }
    case 'rparen': {
      emit(
        state.diagnostics,
        state.frames,
        headToken,
        'empty form: expected head symbol after `(`',
        true,
      );
      const form: FormNode = {
        tag: 'form',
        span: { start: token.start, end: headToken.end },
        head: '',
        namespace: null,
        headSpan: { start: headToken.start, end: headToken.start },
        children: [],
      };
      attach(state.frames, form);
      return 'keep-going';
    }
    default: {
      emit(state.diagnostics, state.frames, headToken, 'expected head symbol after `(`', true);
      const step = childStep(topFrame(state.frames));
      state.frames.push({
        kind: {
          kind: 'form',
          head: '',
          namespace: null,
          headSpan: { start: headToken.start, end: headToken.start },
          openStart: token.start,
        },
        parentStep: step.step,
        parentViaKey: step.viaKey,
        children: [],
        pending: null,
      });
      const leaf = makeLeaf(state, headToken);
      if (leaf !== null) attach(state.frames, leaf);
      return 'keep-going';
    }
  }
}

function handleOpenBracket(state: ParserState, token: Token): LoopAction {
  if (state.frames.length >= MAX_PARSE_DEPTH) {
    emit(state.diagnostics, state.frames, token, 'nesting too deep', true);
    return 'stop';
  }
  const step = childStep(topFrame(state.frames));
  state.frames.push({
    kind: { kind: 'vector', openStart: token.start },
    parentStep: step.step,
    parentViaKey: step.viaKey,
    children: [],
    pending: null,
  });
  return 'keep-going';
}

function handleCloseDelimiter(state: ParserState, token: Token): LoopAction {
  if (state.frames.length <= 1) {
    emit(state.diagnostics, state.frames, token, 'unexpected close delimiter at top level', false);
    return 'keep-going';
  }
  const top = topFrame(state.frames);
  const expected: Token['tag'] = top.kind.kind === 'form' ? 'rparen' : 'rbracket';
  if (token.tag !== expected) {
    emit(state.diagnostics, state.frames, token, 'mismatched close delimiter', false);
  }
  state.frames.pop();
  flushPendingFlag(top);
  const node = finalizeFrame(top, token.end);
  attach(state.frames, node);
  return 'keep-going';
}

function handleKeyword(state: ParserState, token: Token): LoopAction {
  const top = topFrame(state.frames);
  flushPendingFlag(top);
  if (top.kind.kind === 'vector') {
    const leaf = makeLeaf(state, token);
    if (leaf !== null) attach(state.frames, leaf);
    return 'keep-going';
  }
  top.pending = {
    key: decodeRange(state.bytes, token.start + 1, token.end),
    keySpan: { start: token.start, end: token.end },
  };
  return 'keep-going';
}

function handleValue(state: ParserState, token: Token): LoopAction {
  const leaf = makeLeaf(state, token);
  if (leaf !== null) attach(state.frames, leaf);
  return 'keep-going';
}

function handleInvalid(state: ParserState, token: Token): LoopAction {
  emit(state.diagnostics, state.frames, token, 'invalid token', true);
  return 'keep-going';
}

function dispatch(state: ParserState, token: Token): LoopAction {
  switch (token.tag) {
    case 'comment_line':
    case 'comment_block':
      return 'keep-going';
    case 'eof':
      return 'stop';
    case 'lparen':
      return handleOpenParen(state, token);
    case 'lbracket':
      return handleOpenBracket(state, token);
    case 'rparen':
    case 'rbracket':
      return handleCloseDelimiter(state, token);
    case 'keyword':
      return handleKeyword(state, token);
    case 'number':
    case 'date':
    case 'time':
    case 'string':
    case 'raw_string':
    case 'true_lit':
    case 'false_lit':
    case 'nil_lit':
    case 'symbol':
      return handleValue(state, token);
    case 'invalid':
      return handleInvalid(state, token);
  }
}

/** Close every frame left open at EOF, innermost first, then freeze roots. */
function closeUnclosedFrames(state: ParserState): void {
  const eof: Token = { tag: 'eof', start: state.bytes.length, end: state.bytes.length };
  while (state.frames.length > 1) {
    // Emit before popping so buildPath still names the open frame.
    emit(state.diagnostics, state.frames, eof, 'unclosed delimiter at end of input', false);
    const top = topFrame(state.frames);
    state.frames.pop();
    flushPendingFlag(top);
    const node = finalizeFrame(top, state.bytes.length);
    attach(state.frames, node);
  }
}

/**
 * Parse one encoded source. Never throws for SJON syntax: invalid tokens and
 * structural deviations become diagnostics and a partial forest.
 *
 * Complexity O(bytes) plus the frame stack; memory is bounded by
 * `MAX_PARSE_DEPTH`. Pre: `bytes` is the `TextEncoder` view of one source.
 */
export function parse(bytes: Uint8Array): ParsedSource {
  const state: ParserState = {
    bytes,
    lexer: new Lexer(bytes),
    frames: [rootFrame()],
    diagnostics: [],
  };

  while (true) {
    const action = dispatch(state, state.lexer.next());
    if (action === 'stop') break;
  }

  closeUnclosedFrames(state);
  flushPendingFlag(topFrame(state.frames));
  const roots = finalizeRoot(state);
  return { roots, diagnostics: state.diagnostics };
}
