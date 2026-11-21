// The public `fields` view over a form's existing children.
//
// This module intentionally has no pairing logic. `parser.ts` runs the one
// greedy `:key value` pass; re-deriving pairs here could disagree with the
// tree (for example, by pairing a positional keyword that the parser already
// committed as a flag). The view only filters `children`, keeps their source
// order, and preserves duplicates. `get` scans `pairs` backwards so the last
// source-order pair wins.

import type { FormNode, KvpairNode, Node } from './nodes.ts';

export interface FormFields {
  readonly pairs: readonly KvpairNode[];
  readonly positionals: readonly Node[];
  /** Last source-order pair wins; duplicates remain available in `pairs`. */
  get(key: string): Node | undefined;
}

/**
 * Return a read-only view of one form's pair and positional children.
 *
 * Pre: `form` is a form node (checked at runtime because JS callers are not
 * limited by the TypeScript type). Post: `pairs` and `positionals` are new
 * arrays containing the existing child nodes in source order, and no node is
 * copied or re-paired. Throws `TypeError` for a non-form argument.
 * Complexity O(children).
 */
export function fields(form: FormNode): FormFields {
  if (form?.tag !== 'form') {
    throw new TypeError('fields expects a form node');
  }

  const pairs: KvpairNode[] = [];
  const positionals: Node[] = [];
  for (const child of form.children) {
    if (child.tag === 'kvpair') {
      pairs.push(child);
    } else {
      positionals.push(child);
    }
  }

  return {
    pairs,
    positionals,
    get(key: string): Node | undefined {
      for (let index = pairs.length - 1; index >= 0; index -= 1) {
        const pair = pairs[index];
        if (pair !== undefined && pair.key === key) return pair.value;
      }
      return undefined;
    },
  };
}
