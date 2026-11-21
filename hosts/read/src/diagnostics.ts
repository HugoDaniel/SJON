// Diagnostic shape for total/recovery consumers.
//
// `code` stays a plain string rather than a TS union: the closed, wire-stable
// enum is `Ast.Diagnostic.Code` in Zig, and mirroring its member list here
// would create a second source of truth that drifts without a compiler error.
// The reader's own codes are pinned by the tests that fire them.

import type { Span } from './nodes.ts';

export interface ReadDiagnostic {
  /** Snake_case identifier from the engine's diagnostic enum. */
  readonly code: string;
  readonly severity: 'err' | 'warning';
  /** Human-readable prose; never compare this across hosts. */
  readonly message: string;
  readonly span: Span;
  /** Semantic path: form heads, kvpair keys, vector indices. */
  readonly path: readonly string[];
}
