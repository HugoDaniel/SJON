// Edit data model — the pure, backend-free substrate of the write-back side.
//
// An `EditAction` is the JSON action the engine's `sjon_apply_edit`
// (`src/Edit.zig`) consumes: one of five ops over a `path` into a parsed
// document. A `path` step is a *number* (positional / vector index), a
// *string* (kvpair key), or empty `[]` (the root form). The engine re-prints
// in `.full` mode, so trivia (comments, formatting) OUTSIDE the edited subtree
// survives — the whole reason to edit rather than re-`create`→serialize.
//
// This module is the leaf of the edit stack: it imports only the `SjonValue`
// *type* (the action payload shape, identical to plan-02's value model) and
// owns no engine handle. The gate / glue / error remapping live one layer up
// in `backend.ts`, which type-imports `EditAction` from here — so there is no
// runtime cycle (this file never imports `backend.ts`).
//
// Lifetime: pure functions over JS-owned immutable data. No allocator handle.

import { CHILDREN_KEY, FORM_KEY, NS_KEY } from './discriminators.ts';
import type { SjonValue } from './value.ts';

/** A path into a document: number = positional/vector index, string = kvpair key. */
export type EditPath = readonly (string | number)[];

/**
 * One structural edit. Mirrors the action shape `src/Edit.zig` decodes; the
 * `value` payload is `Json.fromJson`'d there, so it is exactly a {@link SjonValue}
 * (`$`-tagged) — `v.*` / `e.*` / `Form.create` values flow straight through.
 */
export type EditAction =
  | {
      readonly op: 'set_keyword';
      readonly path: EditPath;
      readonly key: string;
      readonly value: SjonValue;
    }
  | { readonly op: 'remove_keyword'; readonly path: EditPath; readonly key: string }
  | { readonly op: 'replace'; readonly path: EditPath; readonly value: SjonValue }
  | {
      readonly op: 'insert_positional';
      readonly path: EditPath;
      readonly value: SjonValue;
      readonly index?: number;
    }
  | { readonly op: 'remove_positional'; readonly path: EditPath; readonly index: number };

// ---------------------------------------------------------------------------
// Action builders — the deep/positional escape hatch (`edit.*`)
// ---------------------------------------------------------------------------

/** Set (or replace) kvpair `key` on the form at `path`. */
export function setKey(path: EditPath, key: string, value: SjonValue): EditAction {
  return { op: 'set_keyword', path, key, value };
}

/** Remove kvpair `key` from the form at `path`. */
export function removeKey(path: EditPath, key: string): EditAction {
  return { op: 'remove_keyword', path, key };
}

/**
 * Replace the value at `path` wholesale. `path` must be non-empty — the engine
 * cannot replace the document root (edit its keys/children instead).
 */
export function replace(path: EditPath, value: SjonValue): EditAction {
  if (path.length === 0) {
    throw new Error(
      'SJON edit: replace([], …) is forbidden — the engine cannot replace the ' +
        'document root. Edit a key or positional child of the root instead.',
    );
  }
  return { op: 'replace', path, value };
}

/**
 * Insert `value` as a positional child of the form/vector at `path`. With no
 * `index`, appends; otherwise inserts before `index`. Omits the `index` field
 * entirely when undefined (exactOptionalPropertyTypes).
 */
export function insertChild(path: EditPath, value: SjonValue, index?: number): EditAction {
  return index === undefined
    ? { op: 'insert_positional', path, value }
    : { op: 'insert_positional', path, value, index };
}

/** Remove the positional child at `index` of the form/vector at `path`. */
export function removeChild(path: EditPath, index: number): EditAction {
  return { op: 'remove_positional', path, index };
}

// ---------------------------------------------------------------------------
// Structural equality + the shallow differ (powers `Form.patch`)
// ---------------------------------------------------------------------------

/**
 * Structural deep-equality specialized for {@link SjonValue}: primitives (incl.
 * bigint) by `===`, arrays elementwise, objects (branded atoms `{$sym}`/`{$num}`/
 * … and forms `{$form,…}`) by their defined-valued own keys, key-order-independent.
 * A key whose value is `undefined` is treated as absent (matches the printer,
 * which omits absent optionals). Complexity O(n) over the value tree; pure.
 */
export function sjonValueEqual(a: SjonValue, b: SjonValue): boolean {
  if (a === b) return true;
  if (typeof a !== typeof b) return false;
  if (typeof a !== 'object' || a === null || b === null) return false; // primitives: === already failed
  const aArr = Array.isArray(a);
  if (aArr !== Array.isArray(b)) return false;
  if (aArr) {
    const av = a as readonly SjonValue[];
    const bv = b as readonly SjonValue[];
    if (av.length !== bv.length) return false;
    for (let i = 0; i < av.length; i++) {
      if (!sjonValueEqual(av[i]!, bv[i]!)) return false;
    }
    return true;
  }
  const ao = a as Record<string, unknown>;
  const bo = b as Record<string, unknown>;
  const aKeys = definedKeys(ao);
  const bKeys = definedKeys(bo);
  if (aKeys.length !== bKeys.length) return false;
  for (const k of aKeys) {
    if (bo[k] === undefined) return false; // present-in-a, absent/undefined-in-b
    if (!sjonValueEqual(ao[k] as SjonValue, bo[k] as SjonValue)) return false;
  }
  return true;
}

function definedKeys(o: Record<string, unknown>): readonly string[] {
  return Object.keys(o).filter((k) => o[k] !== undefined);
}

/**
 * A shallow, update-only, minimal-churn diff: emit a root `set_keyword` for each
 * top-level key in `partial` that is new or whose value differs from `current`.
 * `undefined` means "leave this key alone" (removal is explicit — `edit.removeKey`
 * / handle `.remove`); the structural tags `$form`/`$ns`/`$children` are never
 * touched. Minimal churn ⇒ kvpairs that don't change (and their comments) are
 * never re-emitted. The path is `[]` (the root form). Pure.
 */
export function diffToActions(
  current: SjonValue,
  partial: Readonly<Record<string, SjonValue | undefined>>,
): EditAction[] {
  const actions: EditAction[] = [];
  const cur = (current ?? {}) as Record<string, unknown>;
  for (const key of Object.keys(partial)) {
    if (key === FORM_KEY || key === NS_KEY || key === CHILDREN_KEY) continue;
    const next = partial[key];
    if (next === undefined) continue; // leave alone
    const prev = cur[key];
    if (prev === undefined || !sjonValueEqual(prev as SjonValue, next)) {
      actions.push({ op: 'set_keyword', path: [], key, value: next });
    }
  }
  return actions;
}
