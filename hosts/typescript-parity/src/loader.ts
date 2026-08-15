// Manifest loader — second-host TypeScript implementation.
//
// Walks a parsed `(plugin …)` form tree and materialises a Plugin
// suitable for `validate(schema, …)`. Subset corresponding to the
// corpus needs: name, forms (with keys + positional + open),
// value-kinds (with underlying + heads + members).

import type { Node, FormNode, Span } from './ast.ts';
import type { Diagnostic } from './diagnostics.ts';
import {
  MAX_FORM_KEYS,
  MAX_KEYWORDS,
  MAX_LOCAL_FORM_DEPTH,
  SUPPORTED_SJON_FORMAT,
  type Alternative,
  type Arity,
  type Cardinality,
  type CrossRefProvider,
  type ExclusiveGroup,
  type ExprFunc,
  type FlagDecl,
  type FormSpec,
  type KeyDefault,
  type KeySpec,
  type Member,
  type NumericBound,
  type NumericBounds,
  type Plugin,
  type PositionalSpec,
  type QualifiedRef,
  type Repr,
  type StringBounds,
  type StringFormat,
  type UnitShape,
  type ValueKind,
  type ValueType,
  type Variant,
} from './plugin.ts';
import * as StringFormats from './stringFormats.ts';

export interface LoadResult {
  readonly plugin: Plugin;
  /// Manifest-shape failures (no single `(plugin …)` root etc). These are
  /// fixture-author bugs, distinct from the diagnostic-coded conditions
  /// below — surface them up so the caller can fast-fail without trying
  /// to inspect a meaningless plugin.
  readonly errors: readonly string[];
  /// Diagnostic-coded loader-phase emissions (e.g. `too_many_keys` when a
  /// form declares more than MAX_FORM_KEYS keys). Mirrors the load-phase
  /// half of `ManifestLoader.Result.diagnostics` in the Zig host.
  readonly diagnostics: readonly Diagnostic[];
}

export function loadManifest(roots: readonly Node[]): LoadResult {
  const errors: string[] = [];
  const empty: Plugin = {
    name: '',
    version: '',
    authors: [],
    license: '',
    homepage: '',
    repository: '',
    keywords: [],
    sjonFormat: '',
    forms: [],
    exprFuncs: [],
    valueKinds: [],
    crossRefProviders: [],
  };

  if (roots.length !== 1) {
    errors.push('manifest must have exactly one (plugin …) root');
    return { plugin: empty, errors, diagnostics: [] };
  }
  const root = roots[0]!;
  if (root.tag !== 'form' || root.head !== 'plugin') {
    errors.push('manifest root must be a `(plugin …)` form');
    return { plugin: empty, errors, diagnostics: [] };
  }

  let name = '';
  let version = '';
  let wasmFile: string | undefined;
  let wasmSha256: string | undefined;
  let authors: string[] = [];
  let license = '';
  let homepage = '';
  let repository = '';
  let keywords: string[] = [];
  let sjonFormat = '';
  const forms: FormSpec[] = [];
  const valueKinds: ValueKind[] = [];
  const exprFuncs: ExprFunc[] = [];
  const crossRefProviders: CrossRefProvider[] = [];
  const diagnostics: Diagnostic[] = [];

  for (const child of root.children) {
    if (child.tag === 'kvpair') {
      switch (child.key) {
        case 'name':
          if (child.value.tag === 'symbol') name = child.value.text;
          break;
        case 'version':
          if (child.value.tag === 'string') version = child.value.value;
          break;
        case 'wasm-file':
          if (child.value.tag === 'string') wasmFile = child.value.value;
          break;
        case 'wasm-sha256':
          if (child.value.tag === 'string') {
            const pin = child.value.value;
            if (!isWellFormedSha256Pin(pin)) {
              diagnostics.push({
                code: 'plugin_wasm_self_hash_malformed',
                message: `:wasm-sha256 must be \`sha256-<64 lowercase hex chars>\`; got \`${pin}\``,
                path: ['plugin'],
                span: child.value.span,
                severity: 'err',
              });
            }
            wasmSha256 = pin;
          }
          break;
        case 'authors':
          if (child.value.tag === 'vector') {
            authors = parseAuthorsList(child.value.elements);
          }
          break;
        case 'license':
          if (child.value.tag === 'string') {
            license = child.value.value;
            if (!isRecognizedSpdx(license)) {
              diagnostics.push({
                code: 'license_unrecognized',
                message: `:license \`${license}\` is not a canonical SPDX identifier`,
                path: ['plugin'],
                span: child.value.span,
                severity: 'warning',
              });
            }
          }
          break;
        case 'homepage':
          if (child.value.tag === 'string') homepage = child.value.value;
          break;
        case 'repository':
          if (child.value.tag === 'string') repository = child.value.value;
          break;
        case 'keywords':
          if (child.value.tag === 'vector') {
            keywords = parseSymbolList(child.value.elements);
            if (keywords.length > MAX_KEYWORDS) {
              diagnostics.push({
                code: 'too_many_keywords',
                message: `:keywords has ${keywords.length} entries; advisory cap is ${MAX_KEYWORDS}`,
                path: ['plugin'],
                span: child.value.span,
                severity: 'warning',
              });
            }
          }
          break;
        case 'sjon':
          if (child.value.tag === 'string') {
            sjonFormat = child.value.value;
            if (compareSjonFormat(sjonFormat, SUPPORTED_SJON_FORMAT) > 0) {
              diagnostics.push({
                code: 'sjon_format_unsupported',
                message: `manifest declares \`:sjon ${sjonFormat}\` but host implements ${SUPPORTED_SJON_FORMAT}`,
                path: ['plugin'],
                span: child.value.span,
                severity: 'err',
              });
            }
          }
          break;
        // description / other unknown top-level keys: silently ignored,
        // matching the Zig loader (no `unknown_key` on `(plugin …)`).
      }
    } else if (child.tag === 'form') {
      switch (child.head) {
        case 'form':
          forms.push(buildFormSpec(child, diagnostics));
          break;
        case 'value-kind':
          valueKinds.push(buildValueKind(child, diagnostics));
          break;
        case 'expr-func':
          exprFuncs.push(buildExprFunc(child));
          break;
        case 'cross-ref-provider':
          crossRefProviders.push(buildCrossRefProvider(child));
          break;
      }
    }
  }

  // Minimal meta-validation: a `(plugin …)` declaration without `:name`
  // is rejected with `missing_required_key` so the host treats it as a
  // failed load and the downstream data forms see no plugin. Mirrors
  // the Zig meta-validator's emission for the `inline-manifest-invalid`
  // fixture; broader meta-validation is deferred until a fixture demands
  // it.
  if (name === '') {
    diagnostics.push({
      code: 'missing_required_key',
      message: '(plugin …) requires :name',
      path: ['plugin'],
      span: root.headSpan,
      severity: 'err',
    });
  }

  const plugin: Plugin = {
    name,
    version,
    ...(wasmFile !== undefined ? { wasmFile } : {}),
    ...(wasmSha256 !== undefined ? { wasmSha256 } : {}),
    authors,
    license,
    homepage,
    repository,
    keywords,
    sjonFormat,
    forms,
    exprFuncs,
    valueKinds,
    crossRefProviders,
  };
  return { plugin, errors, diagnostics };
}

function parseAuthorsList(elements: readonly Node[]): string[] {
  const out: string[] = [];
  for (const e of elements) {
    if (e.tag === 'string') out.push(e.value);
    else if (e.tag === 'symbol') out.push(e.text);
    else out.push('');
  }
  return out;
}

function parseSymbolList(elements: readonly Node[]): string[] {
  const out: string[] = [];
  for (const e of elements) {
    if (e.tag === 'symbol') out.push(e.text);
    else if (e.tag === 'string') out.push(e.value);
  }
  return out;
}

/// True when `pin` matches `sha256-<64 lowercase hex>` exactly. Mirrors
/// `isWellFormedSha256Pin` in src/ManifestLoader.zig.
function isWellFormedSha256Pin(pin: string): boolean {
  if (pin.length !== 7 + 64) return false;
  if (!pin.startsWith('sha256-')) return false;
  for (let i = 7; i < pin.length; i++) {
    const c = pin.charCodeAt(i);
    const isDigit = c >= 0x30 && c <= 0x39;
    const isLowerHex = c >= 0x61 && c <= 0x66;
    if (!isDigit && !isLowerHex) return false;
  }
  return true;
}

/// Curated subset of common SPDX identifiers. Anything outside this set
/// produces an advisory `license_unrecognized` warning. Mirrors
/// `isRecognizedSpdx` in src/ManifestLoader.zig — keep the two lists in sync.
const CANONICAL_SPDX: readonly string[] = [
  'MIT',
  'Apache-2.0',
  'BSD-2-Clause',
  'BSD-3-Clause',
  'MPL-2.0',
  'ISC',
  'GPL-2.0-only',
  'GPL-2.0-or-later',
  'GPL-3.0-only',
  'GPL-3.0-or-later',
  'LGPL-2.1-only',
  'LGPL-2.1-or-later',
  'LGPL-3.0-only',
  'LGPL-3.0-or-later',
  'AGPL-3.0-only',
  'AGPL-3.0-or-later',
  'Unlicense',
  'CC0-1.0',
  '0BSD',
  'Zlib',
];
function isRecognizedSpdx(lic: string): boolean {
  return CANONICAL_SPDX.includes(lic);
}

/// Compare two `<major>.<minor>` version strings. Returns >0 / 0 / <0.
/// Malformed input compares equal (mirrors Zig `compareSjonFormat`).
function compareSjonFormat(declared: string, supported: string): number {
  const d = parseSimpleVersion(declared);
  const s = parseSimpleVersion(supported);
  if (!d || !s) return 0;
  if (d.major !== s.major) return d.major - s.major;
  return d.minor - s.minor;
}

function parseSimpleVersion(s: string): { major: number; minor: number } | null {
  const dot = s.indexOf('.');
  if (dot < 0) return null;
  const major = Number.parseInt(s.slice(0, dot), 10);
  const minor = Number.parseInt(s.slice(dot + 1), 10);
  if (!Number.isFinite(major) || !Number.isFinite(minor)) return null;
  return { major, minor };
}

function buildFormSpec(form: FormNode, diagnostics: Diagnostic[], depth = 1): FormSpec {
  let name = '';
  let open = false;
  let positional: PositionalSpec = { kind: 'none' };
  const keys: KeySpec[] = [];
  let keyCount = 0;
  let discriminantName: string | null = null;
  let discriminantSpan: Span | null = null;
  const builtVariants: BuiltVariant[] = [];
  const builtGroups: BuiltGroup[] = [];

  for (const child of form.children) {
    if (child.tag === 'kvpair') {
      switch (child.key) {
        case 'name':
          if (child.value.tag === 'symbol') name = child.value.text;
          break;
        case 'discriminant':
          if (child.value.tag === 'symbol') {
            discriminantName = child.value.text;
            discriminantSpan = child.value.span;
          }
          break;
        case 'open':
          if (child.value.tag === 'boolean') open = child.value.value;
          break;
        case 'positional':
          if (child.value.tag === 'symbol') {
            const text = child.value.text;
            if (text === 'any') {
              positional = { kind: 'any' };
            } else {
              const split = splitNamespace(text);
              positional = { kind: 'kind', name: split.name, namespace: split.namespace };
            }
          } else if (child.value.tag === 'form' && child.value.head === 'flag-set') {
            // `(flag-set (flag :name done :description … :link …) …)` —
            // collect each `(flag …)` child's name + optional metadata.
            // Mirrors the Zig parseFlagSet/parseFlagDecl.
            const flags: FlagDecl[] = [];
            for (const flag of child.value.children) {
              if (flag.tag !== 'form' || flag.head !== 'flag') continue;
              let name: string | null = null;
              let description: string | undefined;
              let link: string | undefined;
              for (const fc of flag.children) {
                if (fc.tag !== 'kvpair') continue;
                if (fc.key === 'name' && fc.value.tag === 'symbol') name = fc.value.text;
                else if (fc.key === 'description' && fc.value.tag === 'string')
                  description = fc.value.value;
                else if (fc.key === 'link' && fc.value.tag === 'string') link = fc.value.value;
              }
              if (name !== null) {
                const decl: { name: string; description?: string; link?: string } = { name };
                if (description !== undefined) decl.description = description;
                if (link !== undefined) decl.link = link;
                flags.push(decl);
              }
            }
            positional = { kind: 'flag_set', flags };
          }
          break;
      }
    } else if (child.tag === 'form' && child.head === 'key') {
      keyCount++;
      // Truncation matches the Zig loader: keep only the first
      // MAX_FORM_KEYS so downstream validator code (which assumes
      // `keys.length <= MAX_FORM_KEYS`) stays sound.
      if (keyCount <= MAX_FORM_KEYS) keys.push(buildKeySpec(child, diagnostics, depth));
    } else if (child.tag === 'form' && child.head === 'variant') {
      builtVariants.push(buildVariant(child, diagnostics, depth));
    } else if (child.tag === 'form' && child.head === 'exclusive-group') {
      builtGroups.push(buildExclusiveGroup(child));
    }
  }

  if (keyCount > MAX_FORM_KEYS) {
    diagnostics.push({
      code: 'too_many_keys',
      message: `form \`${name}\` declares ${keyCount} keys, exceeding the maximum of ${MAX_FORM_KEYS}`,
      path: [name],
      span: form.headSpan,
      severity: 'err',
    });
  }

  // Inline positional slot-local forms: `(form …)` children directly under
  // this `(form …)` — the positional mirror of `buildKeySpec`'s key-local arm.
  // Recurse via `buildFormSpec` (depth+1, bounded by MAX_LOCAL_FORM_DEPTH);
  // first occurrence wins on a name clash (the validator resolves local-first
  // by first match). Locals with no `:positional` imply `any` so they aren't
  // dead behind `positional_not_allowed` (mirrors the Zig loader ergonomic); a
  // `(flag-set …)` positional conflicts with locals and is a core-owned
  // `invalid_manifest`, which this validation-parity port (well-formed input
  // only) does not re-check.
  const localForms: FormSpec[] = [];
  if (depth < MAX_LOCAL_FORM_DEPTH) {
    const seen = new Set<string>();
    for (const child of form.children) {
      if (child.tag !== 'form' || child.head !== 'form') continue;
      const local = buildFormSpec(child, diagnostics, depth + 1);
      if (seen.has(local.name)) continue;
      seen.add(local.name);
      localForms.push(local);
    }
  }
  if (localForms.length > 0 && positional.kind === 'none') positional = { kind: 'any' };

  // `:discriminant` names one of this form's own keys. Resolve it to an index
  // here so the validator never re-scans; a name matching no key is
  // structurally an `unknown_key` against the form *declaration* (mirrors the
  // Zig loader) and leaves `discriminantIdx` unset, so no consumer can index
  // past `keys`.
  let discriminantIdx: number | null = null;
  if (discriminantName !== null) {
    const di = keys.findIndex((k) => k.name === discriminantName);
    if (di >= 0) {
      discriminantIdx = di;
    } else {
      diagnostics.push({
        code: 'unknown_key',
        message: `form \`${name}\` declares discriminant \`:${discriminantName}\` but no such key is defined`,
        path: [name, 'discriminant'],
        span: discriminantSpan ?? form.headSpan,
        severity: 'err',
      });
    }
  }

  // Exclusive groups resolve *after* the child sweep rather than inline with
  // it: validating an alt's key names needs the complete `keys` list, and the
  // diagnostic messages need `:name`, which a manifest may legally write after
  // its `(exclusive-group …)` children. (The Zig loader resolves at the same
  // point for the first reason; deferring the name read is this port being
  // insensitive to child order where Zig is not.)
  const exclusiveGroups = resolveExclusiveGroups(
    builtGroups,
    keys,
    discriminantName,
    name,
    null,
    diagnostics,
  );
  const variants: Variant[] = builtVariants.map((bv) => {
    // A variant's groups name the variant's own keys, and a variant has no
    // discriminant of its own — hence the `null` third argument.
    const groups = resolveExclusiveGroups(bv.groups, bv.keys, null, name, bv.when, diagnostics);
    return groups.length > 0
      ? { when: bv.when, keys: bv.keys, exclusiveGroups: groups }
      : { when: bv.when, keys: bv.keys };
  });

  const spec: Mutable<FormSpec> = { name, keys, positional, open };
  if (localForms.length > 0) spec.localForms = localForms;
  if (discriminantName !== null) spec.discriminantName = discriminantName;
  if (discriminantIdx !== null) spec.discriminantIdx = discriminantIdx;
  if (variants.length > 0) spec.variants = variants;
  if (exclusiveGroups.length > 0) spec.exclusiveGroups = exclusiveGroups;
  return spec;
}

/** Strips `readonly` so the builders above can assemble a spec field by field
 *  and still return it as the frozen-by-convention interface. Optional fields
 *  stay optional, which `exactOptionalPropertyTypes` needs: an absent
 *  `discriminantIdx` must be *missing*, not `undefined`. */
type Mutable<T> = { -readonly [K in keyof T]: T[K] };

/** A `(variant …)` as parsed, before its exclusive groups are resolved
 *  against its own `keys`. Mirrors the split the Zig loader makes between
 *  `buildVariant` and `resolveExclusiveGroups`. */
interface BuiltVariant {
  readonly when: string;
  readonly keys: readonly KeySpec[];
  readonly groups: readonly BuiltGroup[];
}

function buildVariant(form: FormNode, diagnostics: Diagnostic[], depth: number): BuiltVariant {
  let when = '';
  const keys: KeySpec[] = [];
  let keyCount = 0;
  const groups: BuiltGroup[] = [];

  for (const child of form.children) {
    if (child.tag === 'kvpair') {
      if (child.key === 'when' && child.value.tag === 'symbol') when = child.value.text;
    } else if (child.tag === 'form' && child.head === 'key') {
      keyCount++;
      if (keyCount <= MAX_FORM_KEYS) keys.push(buildKeySpec(child, diagnostics, depth));
    } else if (child.tag === 'form' && child.head === 'exclusive-group') {
      groups.push(buildExclusiveGroup(child));
    }
  }

  return { when, keys, groups };
}

/** Intermediate shape captured during the structural walk of
 *  `(exclusive-group …)`. Mirrors `BuiltGroup` in `src/ManifestLoader.zig` —
 *  the real {@link ExclusiveGroup} needs the enclosing scope's `keys`, which
 *  are not known until the child sweep finishes. */
interface BuiltGroup {
  readonly cardinality: Cardinality;
  readonly alternatives: readonly BuiltAlt[];
  readonly span: Span;
}

interface BuiltAlt {
  readonly keys: readonly string[];
  readonly span: Span;
}

function buildExclusiveGroup(form: FormNode): BuiltGroup {
  // An unrecognised `:cardinality` symbol falls back to `exactly-one`, as in
  // the Zig loader — the meta-schema is what rejects the typo.
  let cardinality: Cardinality = 'exactly_one';
  const alternatives: BuiltAlt[] = [];
  for (const child of form.children) {
    if (child.tag === 'kvpair') {
      if (child.key === 'cardinality' && child.value.tag === 'symbol') {
        cardinality = child.value.text === 'at-most-one' ? 'at_most_one' : 'exactly_one';
      }
    } else if (child.tag === 'form' && child.head === 'alt') {
      alternatives.push(buildAlternative(child));
    }
  }
  return { cardinality, alternatives, span: form.headSpan };
}

function buildAlternative(form: FormNode): BuiltAlt {
  let keys: readonly string[] = [];
  let span: Span = form.headSpan;
  for (const child of form.children) {
    if (child.tag !== 'kvpair') continue;
    if (child.key === 'keys' && child.value.tag === 'vector') {
      keys = parseSymbolList(child.value.elements);
      span = child.value.span;
    }
  }
  return { keys, span };
}

/**
 * Validate `builtGroups` against the enclosing scope and produce the
 * {@link ExclusiveGroup} list. Mirrors `resolveExclusiveGroups` in
 * `src/ManifestLoader.zig`, including which failure gets which code:
 * `exclusive_bundle_collision` is the *in-group* repeat (one key named by two
 * alts of the same group), everything else — too few alts, an undeclared key,
 * the discriminant, a key shared across two groups — is
 * `exclusive_group_invalid`.
 *
 * Each failure is reported and the group is still emitted: a malformed group
 * makes the whole manifest fail to load (the host drops a plugin with any
 * err-severity load diagnostic), so the returned value is never consulted.
 */
function resolveExclusiveGroups(
  builtGroups: readonly BuiltGroup[],
  keys: readonly KeySpec[],
  discriminantName: string | null,
  formName: string,
  variantWhen: string | null,
  diagnostics: Diagnostic[],
): ExclusiveGroup[] {
  if (builtGroups.length === 0) return [];

  const seenInAnyGroup = new Set<string>();
  const out: ExclusiveGroup[] = [];
  for (const bg of builtGroups) {
    if (bg.alternatives.length < 2) {
      emitExclusiveInvalid(
        diagnostics,
        bg.span,
        formName,
        variantWhen,
        'exclusive_group_invalid',
        'needs at least 2 alternatives',
      );
    }

    const seenInThisGroup = new Set<string>();
    const alternatives: Alternative[] = [];
    for (const ba of bg.alternatives) {
      for (const kn of ba.keys) {
        if (!keys.some((k) => k.name === kn)) {
          emitExclusiveInvalid(
            diagnostics,
            ba.span,
            formName,
            variantWhen,
            'exclusive_group_invalid',
            `exclusive-group alt names \`${kn}\` but no such key is declared`,
          );
        }
        if (discriminantName !== null && discriminantName === kn) {
          emitExclusiveInvalid(
            diagnostics,
            ba.span,
            formName,
            variantWhen,
            'exclusive_group_invalid',
            `exclusive-group must not name discriminant \`:${discriminantName}\``,
          );
        }
        const inThisGroup = seenInThisGroup.has(kn);
        seenInThisGroup.add(kn);
        if (inThisGroup) {
          emitExclusiveInvalid(
            diagnostics,
            ba.span,
            formName,
            variantWhen,
            'exclusive_bundle_collision',
            `key \`${kn}\` appears in more than one alt of the same exclusive-group`,
          );
        }
        const inAnyGroup = seenInAnyGroup.has(kn);
        seenInAnyGroup.add(kn);
        // Guarded on `!inThisGroup` so an in-group repeat reports once, as
        // the bundle collision — not twice, once per set.
        if (inAnyGroup && !inThisGroup) {
          emitExclusiveInvalid(
            diagnostics,
            ba.span,
            formName,
            variantWhen,
            'exclusive_group_invalid',
            `key \`${kn}\` appears in more than one exclusive-group`,
          );
        }
      }
      alternatives.push({ keys: ba.keys });
    }
    out.push({ alternatives, cardinality: bg.cardinality });
  }
  return out;
}

/** Shared body for the two load-time exclusive-group diagnostics — identical
 *  modulo the code and the pre-formatted reason tail. Mirrors
 *  `emitExclusiveInvalid` in `src/ManifestLoader.zig`. */
function emitExclusiveInvalid(
  diagnostics: Diagnostic[],
  span: Span,
  formName: string,
  variantWhen: string | null,
  code: 'exclusive_group_invalid' | 'exclusive_bundle_collision',
  reason: string,
): void {
  diagnostics.push({
    code,
    message:
      variantWhen !== null
        ? `form \`${formName}\` (variant \`:when ${variantWhen}\`): ${reason}`
        : `form \`${formName}\`: ${reason}`,
    path:
      variantWhen !== null
        ? [formName, variantWhen, 'exclusive-group']
        : [formName, 'exclusive-group'],
    span,
    severity: 'err',
  });
}

function buildKeySpec(form: FormNode, diagnostics: Diagnostic[], depth: number): KeySpec {
  let name = '';
  let valueType: ValueType = { kind: 'any' };
  let optional: boolean | null = null;
  let defaultValue: KeyDefault | null = null;
  for (const child of form.children) {
    if (child.tag !== 'kvpair') continue;
    switch (child.key) {
      case 'name':
        if (child.value.tag === 'symbol') name = child.value.text;
        break;
      case 'type':
        if (child.value.tag === 'symbol') valueType = parseValueType(child.value.text);
        break;
      case 'optional':
        if (child.value.tag === 'boolean') optional = child.value.value;
        break;
      case 'default':
        // A `:default` value makes the key effectively optional + drives the
        // exporter's annotation. Mirrors `ManifestLoader.zig`'s `:default`
        // parse. Type-mismatch validation (`wrong_underlying`) needs the
        // `validateDefaults`/overlay machinery this host does not mirror, so
        // it is out of scope here (see test/conformance.test.ts skip notes).
        defaultValue = parseKeyDefault(child.value);
        break;
    }
  }

  // Spec rule (docs/portable-manifest-v1.md §5.1): an unwritten `:optional`
  // is false for a key with no `:default` and true for one that has it — a
  // default fills the slot, so absence is not a missing key. Mirrors the
  // same fixup at the end of `ManifestLoader.buildKey`; this port used to
  // hardcode `true`, which made every key that omits `:optional` unrequired
  // here and required on the other three hosts. Invisible to the corpus,
  // whose fixtures all write `:optional` explicitly.
  const effective = optional ?? defaultValue !== null;

  // Inline slot-local forms: positional `(form …)` children on a `:type form`
  // slot. Mirrors `ManifestLoader.buildKey`'s `.form` arm — recurse via
  // `buildFormSpec` (depth+1, bounded by MAX_LOCAL_FORM_DEPTH), first
  // occurrence wins on a name clash (the validator resolves local-first by
  // first match). The Zig loader's `invalid_manifest` guards (non-form slot,
  // duplicate, over-depth) are meta-schema/loader concerns owned by the core
  // and its tests; this validation-parity port only builds well-formed input.
  if (valueType.kind === 'form' && depth < MAX_LOCAL_FORM_DEPTH) {
    const localForms: FormSpec[] = [];
    const seen = new Set<string>();
    for (const child of form.children) {
      if (child.tag !== 'form' || child.head !== 'form') continue;
      const local = buildFormSpec(child, diagnostics, depth + 1);
      if (seen.has(local.name)) continue;
      seen.add(local.name);
      localForms.push(local);
    }
    if (localForms.length > 0) {
      return { name, valueType, optional: effective, default: defaultValue, localForms };
    }
  }

  return { name, valueType, optional: effective, default: defaultValue };
}

/**
 * Parse a `:default` value node into a {@link KeyDefault}. Returns `null` for
 * a node that cannot be a default literal (date/time/keyword), matching the
 * Zig core's `Default` union (nil/boolean/number/string/symbol/vector/expr).
 */
function parseKeyDefault(node: Node): KeyDefault | null {
  switch (node.tag) {
    case 'nil':
      return { kind: 'nil' };
    case 'boolean':
      return { kind: 'boolean', value: node.value };
    case 'number':
      return { kind: 'number', value: node.value };
    case 'string':
      return { kind: 'string', value: node.value };
    case 'symbol':
      return { kind: 'symbol', value: node.text };
    case 'vector': {
      const elements: KeyDefault[] = [];
      for (const el of node.elements) {
        const child = parseKeyDefault(el);
        if (child === null) return null; // a non-representable element voids the vector
        elements.push(child);
      }
      return { kind: 'vector', elements };
    }
    case 'form':
      // Expression default: snapshot head/namespace + positional arg count
      // (kvpairs aren't valid in an expr). The exporter annotates head only.
      return {
        kind: 'expression',
        head: node.head,
        namespace: node.namespace,
        argCount: node.children.filter((c) => c.tag !== 'kvpair').length,
      };
    default:
      return null;
  }
}

function parseValueType(text: string): ValueType {
  switch (text) {
    case 'any':
      return { kind: 'any' };
    case 'number':
      return { kind: 'number' };
    case 'string':
      return { kind: 'string' };
    case 'symbol':
      return { kind: 'symbol' };
    case 'boolean':
      return { kind: 'boolean' };
    case 'nil':
      return { kind: 'nil' };
    case 'vector':
      return { kind: 'vector' };
    case 'form':
      return { kind: 'form' };
    case 'expr':
      return { kind: 'expr' };
    default: {
      const split = splitNamespace(text);
      return { kind: 'named', name: split.name, namespace: split.namespace };
    }
  }
}

/// Split a symbol on its first interior `/`. Mirrors `Parser.splitNamespace`
/// in src/Parser.zig — a slash that is the first or last byte is part of
/// the symbol (operators / typos), not a namespace separator.
function splitNamespace(text: string): { name: string; namespace: string | null } {
  const slash = text.indexOf('/');
  if (slash > 0 && slash + 1 < text.length) {
    return { namespace: text.slice(0, slash), name: text.slice(slash + 1) };
  }
  return { name: text, namespace: null };
}

function buildValueKind(form: FormNode, diagnostics: Diagnostic[]): ValueKind {
  let name = '';
  let underlying: ValueKind['underlying'] = 'symbol';
  let heads: string[] | undefined;
  let members: Member[] | undefined;
  let vector: ValueKind['vector'];
  let unit: UnitShape | undefined;
  let numericForm: FormNode | undefined;
  let numericSpan: { start: number; end: number } | undefined;
  let stringBoundsForm: FormNode | undefined;
  let stringBoundsSpan: { start: number; end: number } | undefined;
  let reprForm: FormNode | undefined;
  let reprSpan: { start: number; end: number } | undefined;
  let isScalarOrRef = false;
  let scalarOrRefForm: FormNode | undefined;
  let scalarOrRefSpan: { start: number; end: number } | undefined;
  let unionForm: FormNode | undefined;
  let crossRef: ValueKind['crossRef'];

  // First pass picks up `:name` so the rich-form diagnostics emitted by
  // `readMemberSet` can name the kind.
  let kindName = '';
  for (const child of form.children) {
    if (child.tag !== 'kvpair') continue;
    if (child.key === 'name' && child.value.tag === 'symbol') {
      kindName = child.value.text;
      break;
    }
  }

  for (const child of form.children) {
    if (child.tag !== 'kvpair') continue;
    switch (child.key) {
      case 'name':
        if (child.value.tag === 'symbol') name = child.value.text;
        break;
      case 'underlying':
        if (child.value.tag === 'symbol') {
          const u = child.value.text;
          if (u === 'scalar-or-ref') {
            // Surface shorthand — desugars to `union [<base> symbol]` after
            // the loop. Leave `underlying` at its default for now.
            isScalarOrRef = true;
          } else if (u === 'union') {
            // Explicit union — alternatives come from the `:union
            // (union-shape …)` slot parsed below.
            underlying = 'union_of';
          } else if (
            u === 'number' ||
            u === 'string' ||
            u === 'symbol' ||
            u === 'vector' ||
            u === 'form'
          ) {
            underlying = u;
          }
        }
        break;
      case 'heads':
        if (child.value.tag === 'form' && child.value.head === 'head-set') {
          heads = readSymbolList(child.value, 'names');
        }
        break;
      case 'members':
        if (child.value.tag === 'form' && child.value.head === 'member-set') {
          members = readMemberSet(child.value, kindName, diagnostics);
        }
        break;
      case 'vector':
        if (child.value.tag === 'form' && child.value.head === 'vector-shape') {
          vector = readVectorShape(child.value);
          if (vector) validateVectorShape(vector, kindName, child.value.headSpan, diagnostics);
        }
        break;
      case 'unit':
        if (child.value.tag === 'form' && child.value.head === 'unit-shape') {
          unit = readUnitShape(child.value);
        }
        break;
      case 'numeric':
        if (child.value.tag === 'form' && child.value.head === 'numeric-bounds') {
          numericForm = child.value;
          numericSpan = child.value.headSpan;
        }
        break;
      case 'string-bounds':
        if (child.value.tag === 'form' && child.value.head === 'string-bounds') {
          stringBoundsForm = child.value;
          stringBoundsSpan = child.value.headSpan;
        }
        break;
      case 'repr':
        if (child.value.tag === 'form' && child.value.head === 'repr-shape') {
          reprForm = child.value;
          reprSpan = child.value.headSpan;
        }
        break;
      case 'scalar-or-ref':
        if (child.value.tag === 'form' && child.value.head === 'scalar-or-ref-shape') {
          scalarOrRefForm = child.value;
          scalarOrRefSpan = child.value.headSpan;
        }
        break;
      case 'union':
        if (child.value.tag === 'form' && child.value.head === 'union-shape') {
          unionForm = child.value;
        }
        break;
      case 'cross-ref':
        if (child.value.tag === 'form' && child.value.head === 'cross-ref') {
          crossRef = readCrossRef(child.value, name, diagnostics);
        }
        break;
    }
  }
  const kind: ValueKind = { name, underlying };
  if (heads) (kind as { heads?: readonly string[] }).heads = heads;
  if (members) (kind as { members?: readonly Member[] }).members = members;
  if (vector) (kind as { vector?: ValueKind['vector'] }).vector = vector;
  if (unit) (kind as { unit?: UnitShape }).unit = unit;
  if (numericForm && numericSpan) {
    const numeric = readNumericBounds(numericForm);
    checkNumericBoundsConsistency(name, underlying, numeric, numericSpan, diagnostics);
    (kind as { numeric?: NumericBounds }).numeric = numeric;
  }
  if (stringBoundsForm && stringBoundsSpan) {
    const sb = readStringBounds(stringBoundsForm);
    checkStringBoundsConsistency(
      name,
      underlying,
      sb,
      stringBoundsForm,
      stringBoundsSpan,
      members,
      diagnostics,
    );
    (kind as { stringBounds?: StringBounds }).stringBounds = sb;
  }
  if (reprForm && reprSpan) {
    const repr = readReprShape(reprForm);
    checkReprConsistency(name, underlying, reprSpan, diagnostics);
    if (repr) (kind as { repr?: Repr }).repr = repr;
  }
  if (crossRef) (kind as { crossRef?: ValueKind['crossRef'] }).crossRef = crossRef;
  // Explicit `:underlying union` + `:union (union-shape :alternatives […])` —
  // the raw union form (e.g. the audio plugin's note-or-event). The
  // scalar-or-ref shorthand is desugared separately just below.
  if (underlying === 'union_of' && unionForm) {
    (kind as { unionOf?: ValueKind['unionOf'] }).unionOf = readUnionShape(unionForm);
  }
  // Desugar `:underlying scalar-or-ref` → `union [<base> symbol]` last, so
  // the earlier consistency checks saw the placeholder underlying (parity
  // with the loop ordering in src/ManifestLoader.zig).
  if (isScalarOrRef) {
    if (scalarOrRefForm) {
      (kind as { underlying: ValueKind['underlying'] }).underlying = 'union_of';
      (kind as { unionOf?: ValueKind['unionOf'] }).unionOf = buildScalarOrRefUnion(scalarOrRefForm);
    } else {
      diagnostics.push({
        code: 'invalid_manifest',
        message: `value-kind \`${name}\` declares \`:underlying scalar-or-ref\` but no \`:scalar-or-ref (scalar-or-ref-shape …)\` slot`,
        path: [name, 'scalar-or-ref'],
        span: form.headSpan,
        severity: 'err',
      });
    }
  } else if (scalarOrRefForm && scalarOrRefSpan) {
    diagnostics.push({
      code: 'invalid_manifest',
      message: `value-kind \`${name}\` declares \`:scalar-or-ref\` but \`:underlying\` is \`${underlying}\`, not \`scalar-or-ref\``,
      path: [name, 'scalar-or-ref'],
      span: scalarOrRefSpan,
      severity: 'err',
    });
  }
  return kind;
}

// Desugar `(scalar-or-ref-shape :base <kind>)` into `union [<base> symbol]`.
// Mirrors buildScalarOrRefShape in src/ManifestLoader.zig. A missing `:base`
// is unreachable on a meta-valid manifest (the meta-schema marks it
// required); the degenerate `[symbol]` fallback keeps the kind well-formed.
// Read an explicit `(union-shape :alternatives [a b …])` slot into a
// unionOf. Each alternative is a symbol that may carry a namespace
// (`ns/name`); non-symbol elements are skipped. Mirrors the Zig loader's
// union-shape parsing.
function readUnionShape(form: FormNode): { alternatives: QualifiedRef[] } {
  const alternatives: QualifiedRef[] = [];
  for (const child of form.children) {
    if (child.tag !== 'kvpair') continue;
    if (child.key !== 'alternatives') continue;
    if (child.value.tag !== 'vector') continue;
    for (const e of child.value.elements) {
      if (e.tag !== 'symbol') continue;
      const split = splitNamespace(e.text);
      alternatives.push({ name: split.name, namespace: split.namespace });
    }
  }
  return { alternatives };
}

function buildScalarOrRefUnion(form: FormNode): { alternatives: QualifiedRef[] } {
  let base: QualifiedRef | undefined;
  for (const c of form.children) {
    if (c.tag !== 'kvpair') continue;
    if (c.key !== 'base') continue;
    if (c.value.tag === 'symbol') {
      const split = splitNamespace(c.value.text);
      base = { name: split.name, namespace: split.namespace };
    }
  }
  const symbolAlt: QualifiedRef = { name: 'symbol', namespace: null };
  return { alternatives: base ? [base, symbolAlt] : [symbolAlt] };
}

// Parse `(repr-shape :type <f32|u32|i32|u16|f16>)`. Returns undefined when
// the `:type` is absent or unrecognised — the meta-schema's required
// `:type` + `repr-type-tag` member-set make that unreachable on a valid
// manifest. Mirrors `buildReprShape` in src/ManifestLoader.zig.
function readReprShape(form: FormNode): Repr | undefined {
  for (const c of form.children) {
    if (c.tag !== 'kvpair') continue;
    if (c.key !== 'type') continue;
    if (c.value.tag !== 'symbol') continue;
    const t = c.value.text;
    if (t === 'f32' || t === 'u32' || t === 'i32' || t === 'u16' || t === 'f16') return t;
  }
  return undefined;
}

// `:repr` only refines a `.number` underlying; on any other underlying it
// is an authoring mistake flagged `invalid_manifest` (mirroring the
// unit/numeric consistency precedent — no repr-specific manifest code).
// Parity with `checkReprShapeConsistency` in src/ManifestLoader.zig.
function checkReprConsistency(
  kindName: string,
  underlying: ValueKind['underlying'],
  span: { start: number; end: number },
  diagnostics: Diagnostic[],
): void {
  if (underlying === 'number') return;
  diagnostics.push({
    code: 'invalid_manifest',
    message: `value-kind \`${kindName}\` declares \`:repr\` but \`:underlying\` is \`${underlying}\`, not \`number\``,
    path: [kindName, 'repr'],
    span,
    severity: 'err',
  });
}

function readNumericBounds(form: FormNode): NumericBounds {
  let min: NumericBound | undefined;
  let max: NumericBound | undefined;
  let exclusiveMin = false;
  let exclusiveMax = false;
  let integer = false;
  for (const c of form.children) {
    if (c.tag !== 'kvpair') continue;
    switch (c.key) {
      case 'min':
        if (c.value.tag === 'number') min = readBound(c.value);
        break;
      case 'max':
        if (c.value.tag === 'number') max = readBound(c.value);
        break;
      case 'exclusive-min':
        if (c.value.tag === 'boolean') exclusiveMin = c.value.value;
        break;
      case 'exclusive-max':
        if (c.value.tag === 'boolean') exclusiveMax = c.value.value;
        break;
      case 'integer':
        if (c.value.tag === 'boolean') integer = c.value.value;
        break;
    }
  }
  const out: NumericBounds = { exclusiveMin, exclusiveMax, integer };
  if (min) (out as { min?: NumericBound }).min = min;
  if (max) (out as { max?: NumericBound }).max = max;
  return out;
}

function readBound(node: { value: number; unit?: string; integerBits?: bigint }): NumericBound {
  const bound: NumericBound = {
    value: node.value,
    exactInt: node.integerBits !== undefined,
  };
  if (node.unit !== undefined) (bound as { unit?: string }).unit = node.unit;
  if (node.integerBits !== undefined)
    (bound as { integerBits?: bigint }).integerBits = node.integerBits;
  return bound;
}

function checkNumericBoundsConsistency(
  kindName: string,
  underlying: ValueKind['underlying'],
  bounds: NumericBounds,
  span: { start: number; end: number },
  diagnostics: Diagnostic[],
): void {
  if (underlying !== 'number') {
    diagnostics.push({
      code: 'numeric_bounds_invalid',
      message: `value-kind \`${kindName}\` declares \`:numeric\` but \`:underlying\` is \`${underlying}\`, not \`number\``,
      path: [kindName, 'numeric'],
      span,
      severity: 'err',
    });
  }
  if (bounds.exclusiveMin && !bounds.min) {
    diagnostics.push({
      code: 'numeric_bounds_invalid',
      message: `value-kind \`${kindName}\` \`:numeric\` sets \`:exclusive-min true\` but \`:min\` is absent`,
      path: [kindName, 'numeric', 'exclusive-min'],
      span,
      severity: 'err',
    });
  }
  if (bounds.exclusiveMax && !bounds.max) {
    diagnostics.push({
      code: 'numeric_bounds_invalid',
      message: `value-kind \`${kindName}\` \`:numeric\` sets \`:exclusive-max true\` but \`:max\` is absent`,
      path: [kindName, 'numeric', 'exclusive-max'],
      span,
      severity: 'err',
    });
  }
  if (bounds.min && bounds.max) {
    const sameUnit =
      (bounds.min.unit === undefined && bounds.max.unit === undefined) ||
      (bounds.min.unit !== undefined && bounds.max.unit === bounds.min.unit);
    if (sameUnit && bounds.min.value > bounds.max.value) {
      diagnostics.push({
        code: 'numeric_bounds_invalid',
        message: `value-kind \`${kindName}\` \`:numeric\` has empty range: :min ${bounds.min.value} > :max ${bounds.max.value}`,
        path: [kindName, 'numeric'],
        span,
        severity: 'err',
      });
    }
  }
}

interface RawLen {
  raw: number;
}

function readRawLen(form: FormNode, key: string): RawLen | null {
  for (const c of form.children) {
    if (c.tag !== 'kvpair') continue;
    if (c.key !== key) continue;
    if (c.value.tag === 'number') return { raw: c.value.value };
  }
  return null;
}

function readStringBounds(form: FormNode): StringBounds {
  let minLen: number | undefined;
  let maxLen: number | undefined;
  let pattern: string | undefined;
  let format: StringFormat | undefined;
  for (const c of form.children) {
    if (c.tag !== 'kvpair') continue;
    switch (c.key) {
      case 'min-len':
        if (c.value.tag === 'number') {
          minLen = c.value.value < 0 ? 0 : Math.floor(c.value.value);
        }
        break;
      case 'max-len':
        if (c.value.tag === 'number') {
          maxLen = c.value.value < 0 ? 0 : Math.floor(c.value.value);
        }
        break;
      case 'pattern':
        if (c.value.tag === 'string') pattern = c.value.value;
        break;
      case 'format':
        if (c.value.tag === 'symbol') {
          const f = StringFormats.fromName(c.value.text);
          if (f) format = f;
        }
        break;
    }
  }
  const out: StringBounds = {};
  if (minLen !== undefined) (out as { minLen?: number }).minLen = minLen;
  if (maxLen !== undefined) (out as { maxLen?: number }).maxLen = maxLen;
  if (pattern !== undefined) (out as { pattern?: string }).pattern = pattern;
  if (format !== undefined) (out as { format?: StringFormat }).format = format;
  return out;
}

function checkStringBoundsConsistency(
  kindName: string,
  underlying: ValueKind['underlying'],
  bounds: StringBounds,
  form: FormNode,
  span: { start: number; end: number },
  members: Member[] | undefined,
  diagnostics: Diagnostic[],
): void {
  if (underlying !== 'string') {
    diagnostics.push({
      code: 'string_bounds_invalid',
      message: `value-kind \`${kindName}\` declares \`:string-bounds\` but \`:underlying\` is \`${underlying}\`, not \`string\``,
      path: [kindName, 'string-bounds'],
      span,
      severity: 'err',
    });
  }
  const rawMin = readRawLen(form, 'min-len');
  const rawMax = readRawLen(form, 'max-len');
  if (rawMin && rawMin.raw < 0) {
    diagnostics.push({
      code: 'string_bounds_invalid',
      message: `value-kind \`${kindName}\` \`:string-bounds\` has negative :min-len ${rawMin.raw}`,
      path: [kindName, 'string-bounds', 'min-len'],
      span,
      severity: 'err',
    });
  }
  if (rawMax && rawMax.raw < 0) {
    diagnostics.push({
      code: 'string_bounds_invalid',
      message: `value-kind \`${kindName}\` \`:string-bounds\` has negative :max-len ${rawMax.raw}`,
      path: [kindName, 'string-bounds', 'max-len'],
      span,
      severity: 'err',
    });
  }
  if (bounds.minLen !== undefined && bounds.maxLen !== undefined && bounds.minLen > bounds.maxLen) {
    diagnostics.push({
      code: 'string_bounds_invalid',
      message: `value-kind \`${kindName}\` \`:string-bounds\` has empty range: :min-len ${bounds.minLen} > :max-len ${bounds.maxLen}`,
      path: [kindName, 'string-bounds'],
      span,
      severity: 'err',
    });
  }
  if (bounds.pattern !== undefined && bounds.pattern.length === 0) {
    diagnostics.push({
      code: 'string_bounds_invalid',
      message: `value-kind \`${kindName}\` \`:string-bounds :pattern\` is the empty string`,
      path: [kindName, 'string-bounds', 'pattern'],
      span,
      severity: 'err',
    });
  }
  if (underlying === 'string' && members) {
    for (const m of members) {
      const cp = StringFormats.codepointLength(m.name);
      if (bounds.minLen !== undefined && cp < bounds.minLen) {
        diagnostics.push({
          code: 'string_bounds_invalid',
          message: `value-kind \`${kindName}\` member "${m.name}" has length ${cp} < :min-len ${bounds.minLen}`,
          path: [kindName, 'string-bounds', 'min-len'],
          span,
          severity: 'err',
        });
      }
      if (bounds.maxLen !== undefined && cp > bounds.maxLen) {
        diagnostics.push({
          code: 'string_bounds_invalid',
          message: `value-kind \`${kindName}\` member "${m.name}" has length ${cp} > :max-len ${bounds.maxLen}`,
          path: [kindName, 'string-bounds', 'max-len'],
          span,
          severity: 'err',
        });
      }
      if (bounds.format && !StringFormats.check(bounds.format, m.name)) {
        diagnostics.push({
          code: 'string_bounds_invalid',
          message: `value-kind \`${kindName}\` member "${m.name}" does not satisfy :format \`${bounds.format}\``,
          path: [kindName, 'string-bounds', 'format'],
          span,
          severity: 'err',
        });
      }
    }
  }
}

function buildExprFunc(form: FormNode): ExprFunc {
  let name = '';
  let arity: Arity = { kind: 'at_least', n: 0 };
  let params: ValueType[] | null = null;
  let result: ValueType | null = null;
  for (const child of form.children) {
    if (child.tag !== 'kvpair') continue;
    switch (child.key) {
      case 'name':
        if (child.value.tag === 'symbol') name = child.value.text;
        break;
      case 'arity':
        arity = readArity(child.value) ?? arity;
        break;
      case 'params':
        if (child.value.tag === 'vector') {
          params = child.value.elements.map((e) =>
            e.tag === 'symbol' ? parseValueType(e.text) : ({ kind: 'any' } as ValueType),
          );
        }
        break;
      case 'result':
        if (child.value.tag === 'symbol') result = parseValueType(child.value.text);
        break;
    }
  }
  return { name, arity, params, result };
}

function readArity(node: Node): Arity | null {
  if (node.tag !== 'form') return null;
  if (node.head === 'fixed') {
    for (const c of node.children) {
      if (c.tag === 'number') return { kind: 'fixed', n: c.value };
    }
  } else if (node.head === 'at_least' || node.head === 'at-least') {
    for (const c of node.children) {
      if (c.tag === 'number') return { kind: 'at_least', n: c.value };
    }
  } else if (node.head === 'range') {
    let min = 0;
    let max = 0;
    for (const c of node.children) {
      if (c.tag !== 'kvpair' || c.value.tag !== 'number') continue;
      if (c.key === 'min') min = c.value.value;
      else if (c.key === 'max') max = c.value.value;
    }
    return { kind: 'range', min, max };
  }
  return null;
}

function readUnitShape(form: FormNode): UnitShape {
  let required = false;
  let reject = false;
  let allowed: string[] = [];
  for (const c of form.children) {
    if (c.tag !== 'kvpair') continue;
    if (c.key === 'required' && c.value.tag === 'boolean') {
      required = c.value.value;
    } else if (c.key === 'reject' && c.value.tag === 'boolean') {
      reject = c.value.value;
    } else if (c.key === 'allowed' && c.value.tag === 'vector') {
      allowed = c.value.elements.map((e) => (e.tag === 'symbol' ? e.text : ''));
    }
  }
  return { required, reject, allowed };
}

function readVectorShape(form: FormNode): ValueKind['vector'] | undefined {
  let element: QualifiedRef | undefined;
  let len: number | undefined;
  let minLen: number | undefined;
  let maxLen: number | undefined;
  for (const child of form.children) {
    if (child.tag !== 'kvpair') continue;
    if (child.key === 'element' && child.value.tag === 'symbol') {
      const split = splitNamespace(child.value.text);
      element = { name: split.name, namespace: split.namespace };
    } else if (child.key === 'len' && child.value.tag === 'number') {
      len = child.value.value;
    } else if (child.key === 'min-len' && child.value.tag === 'number') {
      minLen = child.value.value;
    } else if (child.key === 'max-len' && child.value.tag === 'number') {
      maxLen = child.value.value;
    }
  }
  if (!element) return undefined;
  // Build with conditional assignment so `exactOptionalPropertyTypes` never
  // sees an explicit `undefined` for an absent bound.
  const shape: { element: QualifiedRef; len?: number; minLen?: number; maxLen?: number } = {
    element,
  };
  if (len !== undefined) shape.len = len;
  if (minLen !== undefined) shape.minLen = minLen;
  if (maxLen !== undefined) shape.maxLen = maxLen;
  return shape;
}

/** Reject a `(vector-shape …)` that cannot mean one thing. Mirrors
 *  `ManifestLoader.zig`'s two `vector_bounds_invalid` triggers; the
 *  `:string-bounds` equivalent above has been here since M3, and this is
 *  the same shape of check on the sibling declaration.
 *
 *  Path is `[<kind> vector]`, matching the reference — the value-kind and
 *  the refinement that is wrong, not the individual bound. */
function validateVectorShape(
  shape: NonNullable<ValueKind['vector']>,
  kindName: string,
  span: Span,
  diagnostics: Diagnostic[],
): void {
  if (shape.len !== undefined && (shape.minLen !== undefined || shape.maxLen !== undefined)) {
    diagnostics.push({
      code: 'vector_bounds_invalid',
      message: `value-kind \`${kindName}\` \`:vector\` sets a fixed \`:len\` together with \`:min-len\`/\`:max-len\` — a fixed length already subsumes a range`,
      path: [kindName, 'vector'],
      span,
      severity: 'err',
    });
  }
  if (shape.minLen !== undefined && shape.maxLen !== undefined && shape.minLen > shape.maxLen) {
    diagnostics.push({
      code: 'vector_bounds_invalid',
      message: `value-kind \`${kindName}\` \`:vector\` has empty range: :min-len ${shape.minLen} > :max-len ${shape.maxLen}`,
      path: [kindName, 'vector'],
      span,
      severity: 'err',
    });
  }
}

/// Parse a `(cross-ref …)` refinement, enforcing the two routes'
/// exclusions. Mirrors `buildCrossRef` in `src/ManifestLoader.zig`,
/// including the drop-the-offending-key half: a half-honoured
/// contradiction is worse than either reading, so downstream only ever
/// sees a spec that took exactly one route.
function readCrossRef(
  form: FormNode,
  kindName: string,
  diagnostics: Diagnostic[],
): ValueKind['crossRef'] | undefined {
  let target: string | undefined;
  let nameKey: string | undefined;
  let acyclic: boolean | undefined;
  let scopeForm: string | undefined;
  let provider: string | undefined;
  let sourceKey: string | undefined;
  // Spans for the exclusion diagnostics — key spans, matching Zig.
  let nameKeySpan: Span | undefined;
  let sourceKeySpan: Span | undefined;
  let acyclicSpan: Span | undefined;
  for (const child of form.children) {
    if (child.tag !== 'kvpair') continue;
    if (child.key === 'target' && child.value.tag === 'symbol') {
      target = child.value.text;
    } else if (child.key === 'name-key' && child.value.tag === 'symbol') {
      nameKey = child.value.text;
      nameKeySpan = child.keySpan;
    } else if (child.key === 'acyclic' && child.value.tag === 'boolean') {
      acyclic = child.value.value;
      acyclicSpan = child.keySpan;
    } else if (child.key === 'scope' && child.value.tag === 'symbol') {
      scopeForm = child.value.text;
    } else if (child.key === 'provider' && child.value.tag === 'symbol') {
      provider = child.value.text;
    } else if (child.key === 'source-key' && child.value.tag === 'symbol') {
      sourceKey = child.value.text;
      sourceKeySpan = child.keySpan;
    }
  }
  if (!target) return undefined;

  if (provider !== undefined) {
    if (nameKey !== undefined) {
      diagnostics.push({
        code: 'invalid_manifest',
        message: `value-kind \`${kindName}\` \`:cross-ref\` sets both \`:provider\` and \`:name-key\` — the two extraction routes are exclusive`,
        path: [kindName, 'cross-ref', 'name-key'],
        span: nameKeySpan ?? form.headSpan,
        severity: 'err',
      });
      nameKey = undefined;
    }
    if (acyclic === true) {
      diagnostics.push({
        code: 'invalid_manifest',
        message: `value-kind \`${kindName}\` \`:cross-ref\` sets both \`:provider\` and \`:acyclic true\` — cycle edges are defined per declaration site, and extracted names share one source span`,
        path: [kindName, 'cross-ref', 'acyclic'],
        span: acyclicSpan ?? form.headSpan,
        severity: 'err',
      });
      acyclic = false;
    }
  } else if (sourceKey !== undefined) {
    diagnostics.push({
      code: 'invalid_manifest',
      message: `value-kind \`${kindName}\` \`:cross-ref\` sets \`:source-key\` without \`:provider\` — nothing reads it on the identity route`,
      path: [kindName, 'cross-ref', 'source-key'],
      span: sourceKeySpan ?? form.headSpan,
      severity: 'err',
    });
    sourceKey = undefined;
  }

  const cr: {
    target: string;
    nameKey?: string;
    acyclic?: boolean;
    scopeForm?: string;
    provider?: string;
    sourceKey?: string;
  } = {
    target,
  };
  if (nameKey !== undefined) cr.nameKey = nameKey;
  if (acyclic !== undefined) cr.acyclic = acyclic;
  if (scopeForm !== undefined) cr.scopeForm = scopeForm;
  if (provider !== undefined) cr.provider = provider;
  if (sourceKey !== undefined) cr.sourceKey = sourceKey;
  return cr;
}

/// Parse `(cross-ref-provider :name … :description …)`.
///
/// `:impl` is deliberately dropped: this host is declarative-only and
/// does the same for expr-func `:impl` today. The declaration is what
/// matters here — it is the catalog `(cross-ref :provider …)` resolves
/// against.
function buildCrossRefProvider(form: FormNode): CrossRefProvider {
  let name = '';
  let description = '';
  for (const child of form.children) {
    if (child.tag !== 'kvpair') continue;
    if (child.key === 'name' && child.value.tag === 'symbol') {
      name = child.value.text;
    } else if (child.key === 'description' && child.value.tag === 'string') {
      description = child.value.value;
    }
  }
  return { name, description };
}

function readSymbolList(form: FormNode, key: string): string[] {
  for (const child of form.children) {
    if (child.tag !== 'kvpair') continue;
    if (child.key !== key) continue;
    if (child.value.tag !== 'vector') continue;
    return child.value.elements.map((e) => (e.tag === 'symbol' ? e.text : ''));
  }
  return [];
}

/// Parse a `(member-set …)` form into a `Member[]`. Mirrors
/// `ManifestLoader.buildMemberSet` in src/ManifestLoader.zig — accepts
/// either compact (`:values [a b c]`) or rich (`(member …)` children)
/// authoring shape, rejects mixing both, and emits `invalid_manifest`
/// on the empty / duplicate-name / mixed cases.
function readMemberSet(form: FormNode, kindName: string, diagnostics: Diagnostic[]): Member[] {
  let compactValues: string[] | undefined;
  const richForms: FormNode[] = [];
  for (const child of form.children) {
    if (child.tag === 'kvpair' && child.key === 'values') {
      if (child.value.tag === 'vector') {
        compactValues = child.value.elements.map((e) => (e.tag === 'symbol' ? e.text : ''));
      }
    } else if (child.tag === 'form' && child.head === 'member') {
      richForms.push(child);
    }
  }

  const path = [kindName, 'members'];
  if (compactValues !== undefined && richForms.length > 0) {
    diagnostics.push({
      code: 'invalid_manifest',
      message: `value-kind \`${kindName}\` \`:members\` mixes \`:values\` and \`(member …)\` children — pick one shape`,
      path,
      span: form.headSpan,
      severity: 'err',
    });
  }

  if (compactValues !== undefined) {
    return compactValues.map((n) => ({ name: n }));
  }

  if (richForms.length > 0) {
    const out: Member[] = [];
    for (const decl of richForms) {
      const m = readMemberDecl(decl);
      if (out.some((prior) => prior.name === m.name)) {
        diagnostics.push({
          code: 'invalid_manifest',
          message: `value-kind \`${kindName}\` \`:members\` declares duplicate member \`${m.name}\``,
          path,
          span: decl.headSpan,
          severity: 'err',
        });
      }
      out.push(m);
    }
    return out;
  }

  diagnostics.push({
    code: 'invalid_manifest',
    message: `value-kind \`${kindName}\` \`:members\` declares no members (need \`:values …\` or \`(member …)\` children)`,
    path,
    span: form.headSpan,
    severity: 'err',
  });
  return [];
}

function readMemberDecl(form: FormNode): Member {
  const m: {
    name: string;
    label?: string;
    description?: string;
    deprecated?: boolean;
    deprecationMessage?: string;
  } = { name: '' };
  for (const child of form.children) {
    if (child.tag !== 'kvpair') continue;
    switch (child.key) {
      case 'name':
        if (child.value.tag === 'symbol') m.name = child.value.text;
        break;
      case 'label':
        if (child.value.tag === 'string') m.label = child.value.value;
        break;
      case 'description':
        if (child.value.tag === 'string') m.description = child.value.value;
        break;
      case 'deprecated':
        if (child.value.tag === 'boolean') m.deprecated = child.value.value;
        break;
      case 'deprecation-message':
        if (child.value.tag === 'string') m.deprecationMessage = child.value.value;
        break;
    }
  }
  return m;
}
