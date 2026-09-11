// Native `ValidateBackend` adapter for `@sjon-lang/schema`.
//
// Bridges the host-independent fluent builder to the pure-TS validator +
// schema exporter in this package. There is no SJON value codec here
// (the TS-parity host validates, it doesn't print), so this backend
// supplies `validate` + `exportSchema` only — `Form.validate(...)` and
// `Form.toDts()` work; the data-materializing `.parse` / `.parseValue`
// stay WASM-backend features (they need `toJson` / `fromValue`).
//
//   import { s } from '@sjon-lang/schema';
//   import { nativeBackend } from 'sjon-host-ts/SjonSchemaBackend';
//   s.use(nativeBackend());
//   const diags = Form.validate('(ns/head …)').diagnostics;

import type { BackendDiagnostic, ValidateBackend, ValidateOutcome } from '@sjon-lang/schema';
import { exportSchema, validateDocument, type HostDiagnostic, type HostOptions } from './Host.ts';

function toBackendDiagnostic(d: HostDiagnostic): BackendDiagnostic {
  return {
    code: d.code,
    severity: d.severity,
    message: d.message,
    path: d.path,
    span: d.span,
    phase: d.phase,
  };
}

/**
 * Build a `ValidateBackend` over the native TypeScript validator. The
 * default `HostOptions` validate inline-declared plugins with no resolver
 * — the builder's serialized-manifest path.
 */
export function nativeBackend(options: Partial<HostOptions> = {}): ValidateBackend {
  const hostOptions: HostOptions = {
    projectRoot: null,
    projectFile: null,
    resolver: null,
    ...options,
  };
  return {
    validate(source: string): ValidateOutcome {
      const result = validateDocument(source, hostOptions);
      return { diagnostics: result.diagnostics.map(toBackendDiagnostic) };
    },
    exportSchema(source: string): { tsTypes: string | null } {
      const { exportResult } = exportSchema(source, hostOptions, { target: { tsTypes: true } });
      return { tsTypes: exportResult.tsTypesBytes };
    },
  };
}
