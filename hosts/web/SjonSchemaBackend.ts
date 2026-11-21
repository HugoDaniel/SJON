// WASM `ValidateBackend` adapter for `@sjon-lang/schema`.
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
//
// The backend also implements the optional `validateWithManifest` capability:
// it caches one `PreloadedSchemaHandle` per exact manifest text, so repeated
// documents borrow one compiled schema instead of reparsing the manifest on
// every call. A manifest whose preload report carries any diagnostic is not
// safe on that path — manifest-phase warnings would disappear and aggregate
// errors are not replayed — so its handle is freed immediately, the text is
// cached as rejected, and every call for it uses the builder's historical
// `manifest + "\n\n" + source` composition.

import type { BackendDiagnostic, ValidateBackend, ValidateOutcome } from '@sjon-lang/schema';
import type { SjonHost } from './SjonHost.ts';
import type { HostDiagnostic, HostOptions, PreloadedSchemaHandle } from './types.ts';

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
 *
 * `dispose()` releases every retained preloaded schema; the host's
 * `asyncDispose` is the final backstop if a caller forgets.
 */
export function createWasmBackend(
  host: SjonHost,
  options: Partial<HostOptions> = {},
): ValidateBackend {
  const hostOptions: HostOptions = { projectRoot: null, projectFile: null, ...options };

  // Exact manifest text → retained handle, or `null` once a preload report
  // has shown this text is not usable on the fast path. `null` is a cache
  // entry, not a missing one: it remembers the rejection so a dirty
  // manifest is preloaded at most once, never once per call.
  const manifests = new Map<string, PreloadedSchemaHandle | null>();

  const validate = (source: string): ValidateOutcome => {
    const result = host.validateDocument(source, hostOptions);
    return { diagnostics: result.diagnostics.map(toBackendDiagnostic) };
  };

  const validateWithHandle = (source: string, handle: PreloadedSchemaHandle): ValidateOutcome => {
    const result = host.validateDocument(source, { ...hostOptions, preloaded: handle });
    return { diagnostics: result.diagnostics.map(toBackendDiagnostic) };
  };

  const backend: ValidateBackend = {
    validate,
    validateWithManifest(manifest: string, source: string): ValidateOutcome {
      const cached = manifests.get(manifest);
      if (cached === null) return validate(`${manifest}\n\n${source}`);
      if (cached !== undefined) return validateWithHandle(source, cached);

      const handle = host.preload(manifest);
      // Any diagnostic disqualifies the handle: `diagnostics` includes the
      // per-source manifest-phase reports (a warning counts — it would be
      // absent from a handle-only validation) and the aggregate reports
      // (which a borrowed handle does not replay). Dispose before touching
      // the cache so the rejection is atomic, then keep the old two-LF
      // composition for this exact text forever.
      if (handle.diagnostics.length > 0) {
        handle.dispose();
        manifests.set(manifest, null);
        return validate(`${manifest}\n\n${source}`);
      }

      manifests.set(manifest, handle);
      return validateWithHandle(source, handle);
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
    dispose(): void {
      for (const handle of manifests.values()) {
        if (handle !== null) handle.dispose();
      }
      manifests.clear();
    },
  };
  return backend;
}
