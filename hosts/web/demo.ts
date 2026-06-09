// Runnable walkthrough — load both WASM artifacts, encode some SJON,
// validate / evaluate it via the read-only reader, and print what
// each step produced. Run with `node --experimental-strip-types demo.ts`
// from this dir after `zig build wasm-all`.

import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { SjonEncoder, SjonReader } from './sjon-reader.ts';

const here = path.dirname(fileURLToPath(import.meta.url));
const root = path.resolve(here, '../..');
const encPath = path.join(root, 'zig-out/bin/sjon.wasm');
const readerPath = path.join(root, 'zig-out/bin/sjon-binary.wasm');

const encoder = await SjonEncoder.load(encPath);
const reader = await SjonReader.load(readerPath);

console.log('encoder.describe() =', encoder.describe());
console.log('reader.describe()  =', reader.describe());

// 1. Encode a small scene to Binary IR.
const source = '(scene :bpm 130 (canvas :name "main" [1 2 3]))';
const bin = encoder.toBinary(source);
console.log(`\nencoded ${source.length}-byte source → ${bin.length}-byte binary`);

// 2. Validate the binary via the read-only artifact.
const report = reader.validateBinary(bin);
console.log('validator parse diagnostics:', report.parse_diagnostics.length);
console.log('validator diagnostics:      ', report.diagnostics.length);

// 3. Decode it back via the kitchen-sink artifact.
const reprinted = encoder.fromBinary(bin);
console.log('\nfrom_binary canonical text:');
console.log(reprinted);

// 4. Evaluate a stand-alone safe expression via the binary path.
const exprBin = encoder.toBinary('(+ 1 2 (* 3 4))');
const value = reader.evalExprBinary(exprBin);
console.log('\nevalExprBinary((+ 1 2 (* 3 4))) =', value);
