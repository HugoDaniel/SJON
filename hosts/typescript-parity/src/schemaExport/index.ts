// Schema export — TypeScript-parity entry point.
//
// Wraps the lowering pass + the two emit backends into a single
// `exportSchema(schema, options)` entry mirroring
// `Host.exportSchemaFromSource` over the WASM bridge. Caller already
// holds a TS-parity `Schema` (from `loadManifest` / `Host.load`);
// this module produces the artifacts.

import type { Schema } from '../plugin.ts';
import { emit as emitJsonSchema, emitForPlugin as emitJsonSchemaForPlugin } from './jsonSchema.ts';
import { emit as emitTsTypes, emitForPlugin as emitTsTypesForPlugin } from './tsTypes.ts';
import { lowerSchema } from './lower.ts';
import type { Model, PerPluginArtifact } from './model.ts';
import type { Warning } from './warnings.ts';
import { anyError } from './warnings.ts';

export type ExportTarget = {
  jsonSchema?: boolean;
  tsTypes?: boolean;
  intermediate?: boolean;
};

export type ExportLayout = 'aggregated' | 'per-plugin';

export interface ExportOptions {
  readonly target?: ExportTarget;
  readonly layout?: ExportLayout;
  readonly draft?: '2020-12';
}

export interface ExportResult {
  readonly model: Model;
  readonly warnings: readonly Warning[];
  readonly jsonSchemaBytes: string | null;
  readonly tsTypesBytes: string | null;
  readonly intermediateBytes: string | null;
  readonly perPlugin: readonly PerPluginArtifact[] | null;
  hasErrors(): boolean;
}

const DEFAULT_TARGET: Required<ExportTarget> = {
  jsonSchema: true,
  tsTypes: true,
  intermediate: false,
};

/**
 * Lower the schema and emit every requested artifact. The result is
 * pure data — no allocator handle, no `deinit`. Future calls to
 * `exportSchema` reuse the same input schema without interference.
 */
export function exportSchema(schema: Schema, options: ExportOptions = {}): ExportResult {
  const target: Required<ExportTarget> = { ...DEFAULT_TARGET, ...options.target };
  const layout: ExportLayout = options.layout ?? 'aggregated';

  const { model, warnings } = lowerSchema(schema);

  const jsonSchemaBytes = target.jsonSchema ? emitJsonSchema(model, warnings) : null;
  const tsTypesBytes = target.tsTypes ? emitTsTypes(model, warnings) : null;
  const intermediateBytes = target.intermediate ? emitIntermediate(model, warnings) : null;

  let perPlugin: PerPluginArtifact[] | null = null;
  if (layout === 'per-plugin' && model.plugins.length > 0) {
    perPlugin = model.plugins.map((p) => {
      const filtered = filterWarnings(warnings, p.name);
      return {
        plugin: p.name,
        jsonSchema: target.jsonSchema ? emitJsonSchemaForPlugin(model, p, filtered) : null,
        tsTypes: target.tsTypes ? emitTsTypesForPlugin(model, p, filtered) : null,
        intermediate: target.intermediate
          ? emitIntermediate({ plugins: [p], version: model.version }, filtered)
          : null,
      };
    });
  }

  return {
    model,
    warnings,
    jsonSchemaBytes,
    tsTypesBytes,
    intermediateBytes,
    perPlugin,
    hasErrors() {
      return anyError(warnings);
    },
  };
}

function filterWarnings(warnings: readonly Warning[], pluginName: string): readonly Warning[] {
  return warnings.filter((w) => w.pluginName == null || w.pluginName === pluginName);
}

function emitIntermediate(model: Model, warnings: readonly Warning[]): string {
  // IR dump — mirrors `SchemaExport.emitIntermediate`. JSON-serialize
  // the model directly; the lowering pass already produced
  // serialization-friendly data.
  const ir = {
    version: model.version,
    plugins: model.plugins,
    warnings,
  };
  return JSON.stringify(ir, null, 2) + '\n';
}

export type {
  Model,
  PerPluginArtifact,
  ModelPlugin,
  ModelForm,
  ModelKey,
  ModelValueShape,
} from './model.ts';
export type { Warning, WarningCode, WarningSeverity } from './warnings.ts';
