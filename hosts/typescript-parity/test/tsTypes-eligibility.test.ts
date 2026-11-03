// Unit tests for the scope-agnostic exclusive-group eligibility decision.
//
// Mirrors the `groupState` / `groupStateForScope` tests beside the Zig
// emitter in `src/SchemaExport/TsTypes.zig`. The decision is consumed by the
// structural-arm emission; these tests pin the three states independently of
// it so a later emitter change cannot silently widen or narrow a group.

import { test } from 'node:test';
import assert from 'node:assert/strict';

import type { ModelExclusiveGroup, ModelForm, ModelKey } from '../src/schemaExport/model.ts';
import { groupState, groupStateForScope } from '../src/schemaExport/tsTypes.ts';

function key(name: string, hasDefault = false): ModelKey {
  return {
    name,
    optional: true,
    description: '',
    value: { kind: 'any' },
    default: hasDefault ? { kind: 'nil' } : null,
    requires: [],
  };
}

function form(keys: readonly ModelKey[], open = false): ModelForm {
  return {
    name: 'f',
    description: '',
    keys,
    positional: { kind: 'none' },
    open,
    discriminator: null,
    exclusiveGroups: [],
    lowering: null,
  };
}

const pair: ModelExclusiveGroup = {
  cardinality: 'exactly_one',
  alternatives: [['a'], ['b']],
};

test('groupState: closed default-free group is enforced', () => {
  assert.equal(groupState(form([key('a'), key('b')]), pair), 'enforced');
});

test('groupState: an open scope is skipped-open', () => {
  assert.equal(groupState(form([key('a'), key('b')], true), pair), 'skipped-open');
});

test('groupState: any defaulted alternative key defaults the whole group', () => {
  assert.equal(groupState(form([key('a'), key('b', true)]), pair), 'defaulted');
});

test('groupState: a default outside the group does not default it', () => {
  assert.equal(groupState(form([key('a'), key('b'), key('c', true)]), pair), 'enforced');
});

test('groupState: a defaulted sibling group does not skip an enforced one', () => {
  const keys = [key('a'), key('b'), key('c'), key('d', true)];
  const enforced: ModelExclusiveGroup = {
    cardinality: 'exactly_one',
    alternatives: [['a'], ['b']],
  };
  const defaulted: ModelExclusiveGroup = {
    cardinality: 'at_most_one',
    alternatives: [['c'], ['d']],
  };
  const f = form(keys);
  assert.equal(groupState(f, enforced), 'enforced');
  assert.equal(groupState(f, defaulted), 'defaulted');
});

test('groupState: open wins over a defaulted alternative key', () => {
  assert.equal(groupState(form([key('a'), key('b', true)], true), pair), 'skipped-open');
});

test('groupStateForScope: a variant group reads the variant keys, not the form keys', () => {
  const variantKeys = [key('step'), key('sweep')];
  // Same key name, different scope: the form's `step` carries a default,
  // the variant's does not. The group scopes over the variant's overlay.
  const formKeys = [key('kind'), key('step', true)];
  const stepGroup: ModelExclusiveGroup = {
    cardinality: 'exactly_one',
    alternatives: [['step'], ['sweep']],
  };
  assert.equal(groupStateForScope(false, variantKeys, stepGroup), 'enforced');
  assert.equal(groupStateForScope(false, formKeys, stepGroup), 'defaulted');
});
