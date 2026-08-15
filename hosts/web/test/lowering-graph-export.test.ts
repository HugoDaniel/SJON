// Lowering-graph export round-trip via the web host.
//
// Mirrors schema-export-roundtrip's instinct: call the WASM export, then
// feed the output back through the host to prove it is well-formed. Here
// the artifact is SJON (a `(lowering-graph …)` form), so the round-trip
// is "the exported text re-parses cleanly" — `host.encoder.toBinary`
// parses its input and throws on a syntax error, so a clean conversion
// proves the exported graph is valid SJON.

import { test } from 'node:test';
import assert from 'node:assert/strict';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

import { SjonHost } from '../SjonHost.ts';

const here = path.dirname(fileURLToPath(import.meta.url));
const root = path.resolve(here, '..', '..', '..');
const wasmPath = path.join(root, 'zig-out/bin/sjon.wasm');

test('export-lowering-graph: renders a cross-plugin produces DAG as SJON', async () => {
  // `front/seed` lowers via a bare `row` head that resolves cross-plugin
  // to `back/row`; `back/row` is terminal, so it shows up only as an edge
  // target and gets no node of its own.
  const source = `(plugin :name front :version "1.0.0"
  (form :name seed :open true
    :lowering (lowering :hook front/seed-v1 :produces [row])))
(plugin :name back :version "1.0.0"
  (form :name row (key :name v :type number)))`;

  const host = await SjonHost.load(wasmPath);
  const graph = host.exportLoweringGraph(source, { projectRoot: null, projectFile: null });

  assert.match(graph, /\(lowering-graph/);
  assert.match(graph, /\(node :form "front\/seed" :produces \["back\/row"\]\)/);

  // Round-trip: the exported text is itself valid SJON.
  assert.doesNotThrow(() => host.encoder.toBinary(graph));
});

test('export-lowering-graph: an aggregate with no lowering forms renders the empty graph', async () => {
  const source = `(plugin :name plain :version "1.0.0"
  (form :name scene :open true))
(scene)`;
  const host = await SjonHost.load(wasmPath);
  const graph = host.exportLoweringGraph(source, { projectRoot: null, projectFile: null });
  assert.equal(graph.trim(), '(lowering-graph)');
});
