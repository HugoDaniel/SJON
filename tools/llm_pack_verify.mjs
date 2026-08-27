#!/usr/bin/env node
// Verifier for the LLM pack (examples/llm/). Drives the real `sjon` CLI so a
// green run IS the end-to-end proof that every write→validate→repair flow
// behaves exactly as the pack claims.
//
// Modes:
//   (default)   compare: re-run everything, byte-diff against goldens, fail on drift.
//   --regen     overwrite goldens and generated sections after an intended change.
//   --replay    print each flow's task → attempt → diagnostic → fix transcript.
//
// The CLI is `$SJON_CLI` or `zig-out/bin/sjon` (built by the `install_cli`
// step that `zig build llm-pack-verify` depends on). Run from the repo root;
// the tool asserts `build.zig` is in the cwd because `--format=json` echoes
// the file path as passed, so goldens are only byte-stable with repo-relative
// paths.
//
// Zero dependencies: plain Node ≥ 20 ESM.

import { spawnSync } from 'node:child_process';
import { existsSync, readFileSync, readdirSync, writeFileSync } from 'node:fs';
import { basename, join } from 'node:path';

const ROOT = process.cwd();
const CLI = process.env['SJON_CLI'] ?? join('zig-out', 'bin', 'sjon');
const FLOWS_DIR = join('examples', 'llm', 'flows');

const argv = new Set(process.argv.slice(2));
const REGEN = argv.has('--regen');
const REPLAY = argv.has('--replay');

// ANSI helpers (disabled when NO_COLOR is set or stdout is not a TTY).
const useColor = process.stdout.isTTY && !process.env['NO_COLOR'];
const c = (code, s) => (useColor ? `\x1b[${code}m${s}\x1b[0m` : s);
const green = (s) => c('32', s);
const red = (s) => c('31', s);
const dim = (s) => c('2', s);
const bold = (s) => c('1', s);

/** Fatal setup error: a misconfiguration, not a golden mismatch. */
function bail(msg) {
  console.error(red(`llm-pack-verify: ${msg}`));
  process.exit(2);
}

if (!existsSync('build.zig')) {
  bail('run me from the repo root (no build.zig in the current directory).');
}
if (!existsSync(CLI)) {
  bail(`CLI not found at '${CLI}'. Build it with \`zig build cli\`, or set $SJON_CLI.`);
}

const PROJECT_FILE = 'sjon-project.sjon';

/**
 * Run `sjon validate <relPath> --format=json`, pinned to one schema
 * source so the golden can't move with the checkout.
 *
 * `--no-project` is the default and the right one for a flow whose
 * `(plugin …)` is inline: discovery would otherwise walk up out of the
 * flow directory and hand the document a schema the flow never named.
 * `projectRoot` is the opt-in for the one thing an inline manifest
 * cannot express (a provider, which names compiled code) and pins
 * discovery to that directory rather than disabling it. Passing both
 * flags is an error, hence the branch.
 */
function validate(relPath, projectRoot) {
  const where = projectRoot ? `--project-root=${projectRoot}` : '--no-project';
  const r = spawnSync(CLI, ['validate', relPath, '--format=json', where], {
    cwd: ROOT,
    encoding: 'buffer',
  });
  if (r.error) bail(`failed to spawn CLI: ${r.error.message}`);
  return { stdout: r.stdout, code: r.status ?? -1 };
}

/** Run `sjon export-schema <relPath> --target=json-schema --no-project`. */
function exportSchema(relPath) {
  const r = spawnSync(CLI, ['export-schema', relPath, '--target=json-schema', '--no-project'], {
    cwd: ROOT,
    encoding: 'buffer',
  });
  if (r.error) bail(`failed to spawn CLI: ${r.error.message}`);
  if (r.status !== 0) bail(`export-schema ${relPath} exited ${r.status}.`);
  return r.stdout;
}

/**
 * Regenerate a byte-for-byte golden. In --regen: write `fresh` to `path`.
 * Otherwise: diff `fresh` against the on-disk file and record any drift.
 */
function golden(where, path, fresh) {
  if (REGEN) {
    writeFileSync(path, fresh);
  } else if (!existsSync(path)) {
    fail(where, `${basename(path)} does not exist (run --regen).`);
  } else if (!fresh.equals(readFileSync(path))) {
    fail(where, `${basename(path)} is stale (run --regen if intended).`);
  }
}

/** Size a UTF-8 file: bytes, Unicode codepoints, and a chars/4 token proxy. */
function metrics(path) {
  const text = readFileSync(path, 'utf8');
  const chars = [...text].length;
  return { bytes: Buffer.byteLength(text, 'utf8'), chars, tokens: Math.round(chars / 4) };
}

/** `sjon explain --list --format=json` → Map<code, short>. */
function explainList() {
  const r = spawnSync(CLI, ['explain', '--list', '--format=json'], { cwd: ROOT, encoding: 'utf8' });
  if (r.error) bail(`failed to spawn CLI: ${r.error.message}`);
  if (r.status !== 0) bail(`explain --list exited ${r.status}.`);
  return new Map(JSON.parse(r.stdout).map((e) => [e.code, e.short]));
}

/** Parse `expects:` from a task.md front-matter block. */
function parseExpects(taskPath) {
  const text = readFileSync(taskPath, 'utf8');
  const m = text.match(/^---\n([\s\S]*?)\n---/);
  if (!m) bail(`${taskPath}: missing front-matter block.`);
  const line = m[1].split('\n').find((l) => l.startsWith('expects:'));
  if (!line) bail(`${taskPath}: front-matter has no 'expects:' key.`);
  const raw = line.slice('expects:'.length).trim();
  if (raw === 'clean') return { clean: true, codes: [] };
  return {
    clean: false,
    codes: raw
      .split(',')
      .map((s) => s.trim())
      .filter(Boolean),
  };
}

const failures = [];
const fail = (where, detail) => failures.push({ where, detail });

// ---------------------------------------------------------------------------
// Check 1, flows. For every attempt/step .sjon: validate, byte-diff its
// sibling golden, and enforce the flow's convergence + expects contract.
// ---------------------------------------------------------------------------
function checkFlows() {
  const flows = readdirSync(FLOWS_DIR, { withFileTypes: true })
    .filter((d) => d.isDirectory())
    .map((d) => d.name)
    .sort();
  if (flows.length === 0) bail(`no flows found under ${FLOWS_DIR}.`);

  for (const flow of flows) {
    const dir = join(FLOWS_DIR, flow);
    const taskPath = join(dir, 'task.md');
    if (!existsSync(taskPath)) {
      fail(flow, 'missing task.md');
      continue;
    }
    const expects = parseExpects(taskPath);

    // A flow that ships a project file is validated inside it; the
    // project file itself is configuration, not an attempt, so it never
    // gets a diagnostics golden of its own.
    const projectRoot = existsSync(join(dir, PROJECT_FILE)) ? dir : null;
    const docs = readdirSync(dir)
      .filter((f) => f.endsWith('.sjon') && f !== PROJECT_FILE)
      .sort();
    if (docs.length === 0) {
      fail(flow, 'no .sjon attempts');
      continue;
    }

    const seenCodes = new Set();
    const transcript = [];

    for (const doc of docs) {
      const rel = join(dir, doc);
      const goldenPath = `${rel.slice(0, -'.sjon'.length)}.diagnostics.json`;
      const { stdout, code } = validate(rel, projectRoot);

      if (REGEN) {
        writeFileSync(goldenPath, stdout);
      } else if (!existsSync(goldenPath)) {
        fail(flow, `${doc}: golden ${basename(goldenPath)} does not exist (run --regen).`);
      } else {
        const golden = readFileSync(goldenPath);
        if (!stdout.equals(golden)) {
          fail(
            flow,
            `${doc}: stdout differs from ${basename(goldenPath)} (run --regen if intended).`,
          );
        }
      }

      // Parse for the convergence / expects contract (from live stdout).
      let json;
      try {
        json = JSON.parse(stdout.toString('utf8'));
      } catch {
        fail(flow, `${doc}: CLI stdout is not valid JSON.`);
        continue;
      }
      const diags = json.diagnostics ?? [];
      const clean = diags.length === 0;
      for (const d of diags) seenCodes.add(d.code);

      // Exit code must track diagnostics presence.
      if (clean && code !== 0) fail(flow, `${doc}: clean but exit ${code} (expected 0).`);
      if (!clean && code !== 1)
        fail(flow, `${doc}: has diagnostics but exit ${code} (expected 1).`);

      transcript.push({ doc, clean, codes: diags.map((d) => d.code), diags });
    }

    // Convergence: the final attempt must validate clean, so every repair loop
    // must actually terminate at a valid document.
    const last = transcript[transcript.length - 1];
    if (!last.clean) {
      fail(flow, `final attempt ${last.doc} is not clean; the repair loop does not converge.`);
    }

    // Expects contract.
    if (expects.clean) {
      for (const t of transcript) {
        if (!t.clean) fail(flow, `expects: clean, but ${t.doc} produced ${t.codes.join(', ')}.`);
      }
    } else {
      for (const wanted of expects.codes) {
        if (!seenCodes.has(wanted)) {
          fail(flow, `expects code '${wanted}' but no attempt produced it (a dead example?).`);
        }
      }
    }

    if (REPLAY) printTranscript(flow, taskPath, transcript);
  }
}

function printTranscript(flow, taskPath, transcript) {
  const title = readFileSync(taskPath, 'utf8')
    .split('\n')
    .find((l) => l.startsWith('# '));
  console.log(`\n${bold(flow)}  ${dim(title ? title.slice(2) : '')}`);
  for (const t of transcript) {
    if (t.clean) {
      console.log(`  ${green('✓')} ${t.doc}  ${dim('clean')}`);
    } else {
      for (const d of t.diags) {
        console.log(`  ${red('✗')} ${t.doc}  ${bold(d.code)} at [${(d.path ?? []).join(' ')}]`);
        console.log(`      ${dim(d.message)}`);
      }
    }
  }
}

// ---------------------------------------------------------------------------
// Checks 2 and 3, token comparison. Regenerate the two goldens (JSON Schema
// export + the SJON-side diagnostic), then regenerate TOKENS.md from the
// measured artifacts. All three are byte-diffed.
// ---------------------------------------------------------------------------
const TC_DIR = join('examples', 'llm', 'token-comparison');
const tc = (name) => join(TC_DIR, name);

function checkTokenComparison() {
  // Check 2, the generated goldens.
  golden('token-comparison', tc('contract.schema.json'), exportSchema(tc('contract.sjon')));
  golden(
    'token-comparison',
    tc('sjon-diagnostics.json'),
    validate(tc('contract-broken.sjon')).stdout,
  );

  // Check 3, TOKENS.md, computed from the on-disk artifacts (check 2 has
  // already pinned the generated ones to fresh output).
  const rendered = renderTokensTable();
  golden('token-comparison', tc('TOKENS.md'), Buffer.from(rendered, 'utf8'));
}

function renderTokensTable() {
  const m = (name) => metrics(tc(name));
  const row = (label, x) => `| ${label} | ${x.bytes} | ${x.chars} | ${x.tokens} |`;

  const sjon = m('contract.sjon');
  const jsonSchema = m('contract.schema.json');
  const jsonDoc = m('document.json');
  const jsonTotal = {
    bytes: jsonSchema.bytes + jsonDoc.bytes,
    chars: jsonSchema.chars + jsonDoc.chars,
    tokens: jsonSchema.tokens + jsonDoc.tokens,
  };
  const ratio = (jsonTotal.tokens / sjon.tokens).toFixed(1);

  const sjonDiag = m('sjon-diagnostics.json');
  const ajvErr = m('ajv-error.json');

  return `<!-- GENERATED by tools/llm_pack_verify.mjs. Do not edit; regenerate with \`zig build llm-pack-verify -- --regen\`. -->
# Token comparison: SJON vs JSON + JSON Schema

The same contract (a \`camera\` form with a symbol \`:mode\` and a number
\`:zoom\`) expressed two ways. The **SJON side** is what a model reads and
writes to author against this vocabulary; the **JSON side** is the equivalent
JSON Schema 2020-12 plus a canonical-JSON document.

## Method & biases

- **bytes** is the file size; **chars** counts Unicode codepoints; **≈ tokens**
  is \`chars / 4\`, a tokenizer-independent proxy. Absolute token counts vary by
  a model's BPE vocabulary, but the *ratio* between two plain-text artifacts
  tracks this proxy closely.
- \`contract.schema.json\` is generated by SJON's own \`export-schema\`, a bias
  **in JSON's favor** (a hand-tuned schema might be terser than the exporter's).
- \`document.json\`, \`document-broken.json\`, and \`ajv-error.json\` are
  hand-written representative twins, in standard 2-space JSON.
  \`ajv-error.json\` mirrors what Ajv 2020-12 emits for the \`zom\` typo.
- \`contract.sjon\` carries explanatory comments the JSON side has no equivalent
  for, another bias **against SJON**, kept for readability. The real margin is wider.

## Authoring: schema + one document

| Artifact | bytes | chars | ≈ tokens |
| --- | --: | --: | --: |
${row('SJON: `contract.sjon` (schema + doc, one file)', sjon)}
${row('**SJON side total**', sjon)}
| | | | |
${row('JSON Schema: `contract.schema.json`', jsonSchema)}
${row('JSON: `document.json`', jsonDoc)}
${row('**JSON side total**', jsonTotal)}

**The JSON side is ${ratio}× the SJON side** by the token proxy
(${sjon.tokens} vs ${jsonTotal.tokens} tokens), before the model has read a
single diagnostic.

## Repairing the \`zom\` typo

| Artifact | bytes | chars | ≈ tokens |
| --- | --: | --: | --: |
${row('SJON: `sjon-diagnostics.json`', sjonDiag)}
${row('Ajv: `ajv-error.json` (representative)', ajvErr)}

Both point at \`zom\`. SJON's \`unknown_key\` carries the \`path\` \`[camera, zom]\`
and, in \`--format=rich\`, suggests the nearest declared key \`:zoom\`. Ajv's
\`additionalProperties\` error reports that \`zom\` is *unexpected* but not that
\`zoom\` was meant, and adds a \`oneOf\` failure for noise, and it only runs at
all once the whole JSON Schema above has been shipped alongside it.
`;
}

// ---------------------------------------------------------------------------
// Check 4, PRIMER.md. Regenerate the diagnostics table between the GENERATED
// markers (code + short from the CLI, rot-proof; repair direction curated
// below, seeded from docs/tutorial/14-diagnostics-driven-repair.md), and hold
// the whole file under a char budget so it stays paste-into-context small.
// ---------------------------------------------------------------------------
const PRIMER = join('examples', 'llm', 'PRIMER.md');
const PRIMER_BUDGET = 10_000;
const GEN_BEGIN = '<!-- BEGIN GENERATED: diagnostics -->';
const GEN_END = '<!-- END GENERATED: diagnostics -->';

// The document-authoring codes a model hits most, in table order. `short` is
// pulled live from `sjon explain`; only the repair direction lives here.
const CURATED = [
  ['unknown_form', 'Fix the head spelling, or load / qualify the plugin as `plugin/head`.'],
  [
    'unknown_key',
    'Use the nearest declared key; on a discriminated form set the discriminant key first.',
  ],
  ['duplicate_key', 'Remove the duplicate; a key may appear at most once per form.'],
  ['missing_required_key', 'Add the required key (additive; do not restructure).'],
  ['positional_not_allowed', 'Wrap the child under the right key; often a keyword-pairing slip.'],
  ['wrong_underlying', 'Match the declared kind, e.g. drop quotes to turn a string into a number.'],
  ['not_member', "Use one of the closed set's listed members; do not invent a value."],
  ['not_head_member', "Use a form head the slot's head-set allows."],
  [
    'positional_too_many',
    'Delete the child the diagnostic points at; if the message names a bracketed set, the children are individually fine, so keep one and drop the rest.',
  ],
  [
    'positional_missing',
    'Add a child carrying the named head; if the message names a bracketed set, any one head from it will do.',
  ],
  ['unit_required', 'Add an allowed unit suffix (e.g. `90deg`, not `90`).'],
  ['unit_not_allowed', "Swap the unit for one the slot's allowed list accepts, or drop it."],
  [
    'missing_discriminant_key',
    'Add the discriminant key (e.g. `:kind`) so a variant can be selected.',
  ],
  ['arity_mismatch', "Add or drop arguments to match the function's exact count."],
  ['expr_type_mismatch', "Give the argument the type the function's `:params` declare."],
  ['not_cross_ref', 'Spell the referenced name correctly, or declare the missing target.'],
  [
    'union_no_branch_matched',
    'Rewrite the value to fit one of the alternatives the message lists.',
  ],
];

function renderDiagnosticsTable() {
  const shorts = explainList();
  const rows = ['| Code | Means | Repair |', '| --- | --- | --- |'];
  for (const [code, repair] of CURATED) {
    const short = shorts.get(code);
    if (short === undefined) {
      fail(
        'PRIMER.md',
        `curated code '${code}' has no \`sjon explain\` short. Renamed or removed?`,
      );
      continue;
    }
    rows.push(`| \`${code}\` | ${short} | ${repair} |`);
  }
  return rows.join('\n');
}

function checkPrimer() {
  const text = readFileSync(PRIMER, 'utf8');
  const bi = text.indexOf(GEN_BEGIN);
  const ei = text.indexOf(GEN_END);
  if (bi < 0 || ei < 0 || ei < bi) bail(`${PRIMER}: GENERATED markers missing or out of order.`);

  const table = renderDiagnosticsTable();
  const before = text.slice(0, bi + GEN_BEGIN.length);
  const after = text.slice(ei);
  const rebuilt = `${before}\n${table}\n${after}`;

  if (REGEN) {
    writeFileSync(PRIMER, rebuilt);
  } else if (rebuilt !== text) {
    fail('PRIMER.md', 'generated diagnostics table is stale (run --regen if intended).');
  }

  const chars = [...(REGEN ? rebuilt : text)].length;
  if (chars > PRIMER_BUDGET) {
    fail('PRIMER.md', `${chars} chars exceeds the ${PRIMER_BUDGET}-char budget; trim it.`);
  }
}

// ---------------------------------------------------------------------------
// Check 5, llms.txt drift. The primer is served verbatim in two places:
// the landing page's /llms.txt (landing-page/public/llms.txt) and the repo
// root's llms.txt (what a reader, or an agent, finds at the top of the
// public repo). Keep both byte-identical to PRIMER.md. Runs after
// checkPrimer so --regen copies the fresh primer.
// ---------------------------------------------------------------------------
const LLMS_TXT = join('landing-page', 'public', 'llms.txt');
const LLMS_TXT_ROOT = 'llms.txt';

function checkLlmsTxt() {
  golden('llms.txt', LLMS_TXT, readFileSync(PRIMER));
  golden('llms.txt (root)', LLMS_TXT_ROOT, readFileSync(PRIMER));
}

// ---------------------------------------------------------------------------
// Run all checks, in dependency order (generators before their consumers).
// ---------------------------------------------------------------------------

checkFlows();
checkTokenComparison();
checkPrimer();
checkLlmsTxt();

// ---------------------------------------------------------------------------
// Report.
// ---------------------------------------------------------------------------
if (failures.length > 0) {
  console.error(`\n${red(bold(`✗ ${failures.length} failure(s):`))}`);
  for (const f of failures) console.error(`  ${red('•')} ${bold(f.where)}: ${f.detail}`);
  process.exit(1);
}
console.log(green(REGEN ? '✓ llm-pack goldens regenerated.' : '✓ llm-pack verified.'));
