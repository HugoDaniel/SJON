// Edit data model — the pure, backend-free substrate of the write-back side.
//
// An `EditAction` is the JSON action the engine's `sjon_apply_edit`
// (`src/Edit.zig`) consumes: one of six ops over a `path` into a parsed
// document, or one of two over the document's root list. A `path` step is a
// *number* (positional / vector index), a *string* (kvpair key), or empty `[]`
// (the root form). The engine re-prints
// in `.full` mode, so trivia (comments, formatting) OUTSIDE the edited subtree
// survives — the whole reason to edit rather than re-`create`→serialize.
//
// "Outside the edited subtree" is exact, and `wrap` is why it needs saying:
// the four ops that take a `value` build it from JSON, and the JSON bridge
// carries no comments, so a subtree re-encoded to *compose* with rather than
// to change loses its trivia. `wrap` is the op that does not — it clones the
// node it wraps.
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
 * Fields every op takes, whatever its `op`. Kept as a separate interface
 * because `root` is genuinely orthogonal to the operation — repeating it in
 * six variants would read as six decisions rather than one.
 */
interface EditActionCommon {
  /**
   * Which root of a multi-root document the `path` starts at. A SJON file
   * that declares or references a plugin has several roots, so most real
   * documents need this.
   *
   * Omitting it on a multi-root document is an error (`MultipleRoots`) rather
   * than an implicit `0`: the engine refuses instead of silently editing
   * whichever form happens to come first. Use {@link atRoot} to add it.
   */
  readonly root?: number;
}

/**
 * One structural edit. Mirrors the action shape `src/Edit.zig` decodes; the
 * `value` payload is `Json.fromJson`'d there, so it is exactly a {@link SjonValue}
 * (`$`-tagged) — `v.*` / `e.*` / `Form.create` values flow straight through.
 */
export type EditAction = PathedEditAction | ForestEditAction;

/**
 * The six operations that address a node *inside* one root. Every one takes
 * a `path`, and every one takes {@link EditActionCommon}'s `root`.
 */
export type PathedEditAction = EditActionCommon &
  (
    | {
        readonly op: 'set_keyword';
        readonly path: EditPath;
        readonly key: string;
        readonly value: SjonValue;
      }
    | { readonly op: 'remove_keyword'; readonly path: EditPath; readonly key: string }
    | { readonly op: 'replace'; readonly path: EditPath; readonly value: SjonValue }
    | {
        readonly op: 'wrap';
        readonly path: EditPath;
        readonly value: SjonValue;
        readonly hole: EditPath;
      }
    | {
        readonly op: 'insert_positional';
        readonly path: EditPath;
        readonly value: SjonValue;
        readonly index?: number;
      }
    | { readonly op: 'remove_positional'; readonly path: EditPath; readonly index: number }
  );

/**
 * The two operations that address the document's **root list**. The top level
 * is a container like a form or a vector (LANGUAGE.md §4.1), and these are its
 * insert and remove.
 *
 * Deliberately not `EditActionCommon &`: they take neither `path` nor `root`,
 * and the engine *refuses* both rather than ignoring them, so the type refuses
 * them too. `index` alone says which slot — optional on the insert (omitted
 * appends), required on the remove — exactly as on the positional pair.
 */
export type ForestEditAction =
  | { readonly op: 'insert_root'; readonly value: SjonValue; readonly index?: number }
  | { readonly op: 'remove_root'; readonly index: number };

// ---------------------------------------------------------------------------
// Action builders — the deep/positional escape hatch (`edit.*`)
// ---------------------------------------------------------------------------

/** Set (or replace) kvpair `key` on the form at `path`. */
export function setKey(path: EditPath, key: string, value: SjonValue): PathedEditAction {
  return { op: 'set_keyword', path, key, value };
}

/** Remove kvpair `key` from the form at `path`. */
export function removeKey(path: EditPath, key: string): PathedEditAction {
  return { op: 'remove_keyword', path, key };
}

/**
 * Replace the value at `path` wholesale. `path` must be non-empty — the engine
 * cannot replace the document root (edit its keys/children instead).
 */
export function replace(path: EditPath, value: SjonValue): PathedEditAction {
  if (path.length === 0) {
    throw new Error(
      'SJON edit: replace([], …) is forbidden — the engine cannot replace the ' +
        'document root. Edit a key or positional child of the root instead.',
    );
  }
  return { op: 'replace', path, value };
}

/**
 * Compose the node at `path` into a new parent. `value` is the parent, as an
 * ordinary {@link SjonValue}; `hole` is a path *into `value`* naming the slot
 * the wrapped node lands in, and whatever placeholder sits there (`null` reads
 * best) is discarded.
 *
 * Unlike {@link replace}, `path` may be empty — wrapping the whole root is the
 * motivating case. `hole` may not be: with nowhere for the target to land a
 * wrap is a `replace` with extra syntax, so the engine rejects it and this
 * throws before the round-trip.
 *
 * This is the only op that keeps the wrapped subtree's comments and
 * formatting: the engine clones it rather than rebuilding it from `value`.
 * Spelling the same shape as a `replace` whose value nests the target sends it
 * through the JSON bridge, which carries no comments.
 *
 *     wrap(['x'], { $form: '+', $children: [null, 0.1] }, [0])
 *     // (a :x (* 2 …)) → (a :x (+ (* 2 …) 0.1)), comments and all
 *
 * `hole` steps the decoded *node*, not the JSON object: the engine builds the
 * parent from `value` first, so `$children` is not a step — `[0]` is the
 * parent's first positional child, and a string step is a kvpair key.
 */
export function wrap(path: EditPath, value: SjonValue, hole: EditPath): PathedEditAction {
  if (hole.length === 0) {
    throw new Error(
      'SJON edit: wrap(…, hole) needs a non-empty hole — a wrap with no hole ' +
        'has nowhere to put the node it wraps. Use replace() to discard it.',
    );
  }
  return { op: 'wrap', path, value, hole };
}

/**
 * Insert `value` as a positional child of the form/vector at `path`. With no
 * `index`, appends; otherwise inserts before `index`. Omits the `index` field
 * entirely when undefined (exactOptionalPropertyTypes).
 */
export function insertChild(path: EditPath, value: SjonValue, index?: number): PathedEditAction {
  return index === undefined
    ? { op: 'insert_positional', path, value }
    : { op: 'insert_positional', path, value, index };
}

/** Remove the positional child at `index` of the form/vector at `path`. */
export function removeChild(path: EditPath, index: number): PathedEditAction {
  return { op: 'remove_positional', path, index };
}

/**
 * Insert `value` as a new root of the document. With no `index`, appends after
 * the last root; otherwise inserts before root `index`. `index` equal to the
 * number of roots is the append written out.
 *
 * The value is any {@link SjonValue}, not only a form: `1 2` is a two-root
 * document. Under the layout-preserving apply the new root is separated from
 * its neighbour by a copy of the run that already separates the document's
 * roots — so a file written with blank lines between roots keeps them — and by
 * a single newline when there is no such run to copy.
 *
 * Omits the `index` field entirely when undefined (exactOptionalPropertyTypes).
 */
export function insertRoot(value: SjonValue, index?: number): ForestEditAction {
  return index === undefined ? { op: 'insert_root', value } : { op: 'insert_root', value, index };
}

/**
 * Remove root `index`. Removing the only root leaves a document with no roots,
 * which is a document SJON accepts and {@link insertRoot} can refill — so
 * emptying a file and starting it over are both actions.
 */
export function removeRoot(index: number): ForestEditAction {
  return { op: 'remove_root', index };
}

/**
 * Point `action` at root `index` of a multi-root document. Every builder
 * above produces a root-less action, which the engine accepts only on a
 * single-root document; this is how one reaches a form in a file that also
 * carries `(use-plugin …)`.
 *
 *     atRoot(setKey([], 'bpm', 140), 1)
 *
 * A combinator rather than a parameter on all six builders, because `root`
 * answers "which document fragment" while `path` answers "where inside it" —
 * and only the second is worth repeating six times.
 *
 * Takes a {@link PathedEditAction}, not any action: the two forest builders
 * address the root list itself, and the engine refuses `root` on them.
 */
export function atRoot(action: PathedEditAction, index: number): PathedEditAction {
  return { ...action, root: index };
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
