// Plugin resolver contract — second-host TypeScript implementation.
//
// Mirrors `src/Resolver.zig`: a `(use-plugin "name" …)` form is parsed
// into a `Reference`; a `ResolverFn` maps that reference to a manifest
// (with an optional paired WASM sidecar) or a structured failure. The
// shape the host then plugs into its three-phase pipeline.
//
// Only the parser + types live here. The default Node `fs`-backed
// resolver is in `FilesystemResolver.ts`; the Host's mock-resolver
// tests inject their own `ResolverFn` directly.

import type { FormNode, Span } from './ast.ts';
import type { Diagnostic, DiagnosticCode } from './diagnostics.ts';

export interface Reference {
  readonly name: string;
  readonly explicitPath: string | null;
  // Reserved — accepted by the parser, not enforced. Parity with the
  // Zig resolver until a registry/lockfile lands (D7+).
  readonly version: string | null;
  readonly hash: string | null;
  // Anchored at the name string when present, else at the form span.
  // Host emits resolver-phase diagnostics here.
  readonly span: Span;
}

/// A resolver's reply. Shape-identical to `src/Resolver.zig`'s
/// `Resolution` union, `hosts/web/types.ts`, and `hosts/rust`'s enum: a
/// successful resolution is a manifest that *optionally carries* a paired
/// WASM sidecar, never a bare wasm blob. The pairing invariant is the
/// contract — wasm cannot resolve without a manifest
/// (`docs/executable-plugin-abi.md` §3–§4).
///
/// This host is declarative-only, so a non-null `wasm` is refused with a
/// diagnostic rather than instantiated (see `Host.handleResolution`).
/// That is a capability difference; it is not licence to model the
/// contract differently. A resolver written against the reference has to
/// typecheck here, and until this shape landed it didn't — the old
/// three-arm `manifest_source | wasm_bytes | failure` couldn't express
/// the pairing at all, and the corpus can't catch that because
/// plugin-exec families are skipped in this host.
export type Resolution =
  | { readonly kind: 'manifest'; readonly source: string; readonly wasm: Uint8Array | null }
  | { readonly kind: 'failure'; readonly code: DiagnosticCode; readonly detail: string };

export type ResolverFn = (ref: Reference) => Resolution;

export interface ParsedReference {
  readonly reference: Reference;
  readonly diagnostics: readonly Diagnostic[];
}

/// Parse a `(use-plugin "name" …)` form. Caller is expected to have
/// already verified `form.head === 'use-plugin'` (the host's partition
/// pass does this). All malformations become err-severity diagnostics
/// on the result; an empty `diagnostics` array means clean parse.
export function parseReference(form: FormNode): ParsedReference {
  const diagnostics: Diagnostic[] = [];
  let name = '';
  let nameSeen = false;
  let extraPositionalReported = false;
  let span: Span = form.span;
  let explicitPath: string | null = null;
  let version: string | null = null;
  let hash: string | null = null;

  for (const child of form.children) {
    if (child.tag === 'kvpair') {
      switch (child.key) {
        case 'path':
          explicitPath = expectString(child.value, 'path', diagnostics);
          break;
        case 'version':
          version = expectString(child.value, 'version', diagnostics);
          break;
        case 'hash':
          hash = expectString(child.value, 'hash', diagnostics);
          break;
        default:
          diagnostics.push({
            code: 'unknown_key',
            message: `unknown key \`:${child.key}\` on (use-plugin …); expected :path, :version, or :hash`,
            path: ['use-plugin'],
            span: child.keySpan,
            severity: 'err',
          });
      }
    } else if (child.tag === 'string') {
      if (nameSeen) {
        if (!extraPositionalReported) {
          diagnostics.push({
            code: 'invalid_manifest',
            message: '(use-plugin …) takes a single positional name',
            path: ['use-plugin'],
            span: child.span,
            severity: 'err',
          });
          extraPositionalReported = true;
        }
      } else {
        name = child.value;
        span = child.span;
        nameSeen = true;
      }
    } else if (!nameSeen) {
      // Positional slot is occupied by something other than a string —
      // mirror the Zig parser by squelching the "missing name" follow-up.
      diagnostics.push({
        code: 'invalid_manifest',
        message: '(use-plugin …) name must be a string literal',
        path: ['use-plugin'],
        span: child.span,
        severity: 'err',
      });
      nameSeen = true;
    }
  }

  if (!nameSeen) {
    diagnostics.push({
      code: 'invalid_manifest',
      message: '(use-plugin …) requires a name string',
      path: ['use-plugin'],
      span: form.headSpan,
      severity: 'err',
    });
  }

  return {
    reference: { name, explicitPath, version, hash, span },
    diagnostics,
  };
}

function expectString(
  value: import('./ast.ts').Node,
  keyName: string,
  diagnostics: Diagnostic[],
): string | null {
  if (value.tag !== 'string') {
    diagnostics.push({
      code: 'invalid_manifest',
      message: `(use-plugin …) :${keyName} must be a string`,
      path: ['use-plugin'],
      span: value.span,
      severity: 'err',
    });
    return null;
  }
  return value.value;
}
