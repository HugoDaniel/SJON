// @sjon-lang/read — synchronous, dependency-free SJON reader.
//
// STATUS: Task 4 of docs/plans/consumer-api/02-reader-package.md has landed
// the byte lexer, leaf atoms, and the explicit-frame form/vector parser.
// Clean input now produces source-order trees; Tasks 5–6 still own the
// recovery/depth policy, diagnostic-path parity, and the engine oracle.
//
// Every span is a half-open UTF-8 byte range. `read` is the throwing entry
// (roots only when no err-severity diagnostic fired); `readResult` is total for
// SJON syntax and returns recovered roots plus every diagnostic in engine
// order. `fields` is a view over a form's kvpair children, never a second
// pairing pass, so source order and duplicates survive.

export type { ReadDiagnostic } from './diagnostics.ts';
export type {
  BooleanNode,
  DateNode,
  FormNode,
  KeywordNode,
  KvpairNode,
  NilNode,
  Node,
  NodeBase,
  NumberNode,
  Span,
  StringNode,
  SymbolNode,
  TimeNode,
  VectorNode,
} from './nodes.ts';
export { ReadError, fields, read, readResult } from './read.ts';
export type { FormFields, ReadResult } from './read.ts';
