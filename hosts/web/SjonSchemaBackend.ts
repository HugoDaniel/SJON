// WASM `ValidateBackend` adapter for `@sjon/schema`.
//
// Bridges the host-independent fluent builder to `sjon.wasm`: validation
// runs through `SjonHost.validateDocument`, JSON projection through the
// encoder's `toJson`, value→SJON through `fromJson` (`sjon_from_json`),
// and `.d.ts` export through `SjonHost.exportSchema`. With this registered
// (`s.use(createWasmBackend(host))`), `Form.parse` / `.parseValue` /
// `.toDts` all light up.
//
//   const host = await SjonHost.load('zig-out/bin/sjon.wasm');
//   s.use(createWasmBackend(host));
//   const data = Profile.parse('(bounds/profile :handle "ada" :email "a@b.c")');

import type { BackendDiagnostic, ValidateBackend, ValidateOutcome } from '@sjon/schema';
import type { SjonHost } from './SjonHost.ts';
import type { HostDiagnostic, HostOptions } from './types.ts';

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
 * Build a `ValidateBackend` over a loaded `SjonHost`. `options` supplies
 * the `HostOptions` (project root/file, resolver policy) every
 * `validateDocument` / `exportSchema` call carries; the defaults validate
 * inline-declared plugins with no filesystem resolver — which is exactly
 * the builder's serialized-manifest path.
 */
export function createWasmBackend(
  host: SjonHost,
  options: Partial<HostOptions> = {},
): ValidateBackend {
  const hostOptions: HostOptions = { projectRoot: null, projectFile: null, ...options };
  return {
    validate(source: string): ValidateOutcome {
      const result = host.validateDocument(source, hostOptions);
      return { diagnostics: result.diagnostics.map(toBackendDiagnostic) };
    },
    toJson(source: string): unknown {
      return host.encoder.toJson(source, { mode: 'canonical' });
    },
    fromValue(value: unknown): string {
      return host.encoder.fromJson(value);
    },
    exportSchema(source: string): { tsTypes: string | null } {
      const result = host.exportSchema(source, { ...hostOptions, target: 'typescript' });
      return { tsTypes: result.aggregated?.tsTypes ?? null };
    },
    // Editing is WASM-only: forward to the encoder's `sjon_apply_edit` wrapper,
    // which re-prints in `.full` mode (trivia outside the edit survives) and
    // throws `SjonWasmError` (carrying the Zig error name) on failure —
    // `applyOne` duck-types that into `SjonEditError`. `action` is contextually
    // typed `EditAction` from the `ValidateBackend` return annotation.
    applyEdit(source, action) {
      return host.encoder.applyEdit(source, action);
    },
    // Batched edits collapse `applyAll`'s N round-trips into one
    // `sjon_apply_edits` call. `actions` is contextually typed
    // `readonly EditAction[]` from the `ValidateBackend` return annotation,
    // and `options` carries the layout through to `Edit.Options`.
    applyEdits(source, actions, options) {
      return host.encoder.applyEdits(source, actions, options);
    },
  };
}
