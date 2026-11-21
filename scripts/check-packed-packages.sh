#!/usr/bin/env bash
# Validate the four pnpm-packed release packages (@sjon-lang/schema,
# @sjon-lang/read, @sjon-lang/web, @sjon-lang/highlight) in an empty external
# consumer. Usage: scripts/check-packed-packages.sh /absolute/tarball-dir /absolute/wasm-dir
set -euo pipefail
PACK_DIR="$(cd "${1:?tarball directory required}" && pwd)"
export SJON_WASM_DIR="$(cd "${2:?WASM artifact directory required}" && pwd)"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CONSUMER="$(mktemp -d "${TMPDIR:-/tmp}/sjon-release-consumer.XXXXXX")"
trap 'rm -rf "$CONSUMER"' EXIT
for tarball in "$PACK_DIR"/*.tgz; do
    tar -xOf "$tarball" package/package.json | node -e '
        let input = "";
        process.stdin.on("data", c => input += c);
        process.stdin.on("end", () => {
            const p = JSON.parse(input);
            for (const value of Object.values(p.dependencies ?? {})) {
                if (value.startsWith("workspace:")) throw Error("unrewritten workspace dependency");
            }
            if (!JSON.stringify(p.exports).includes("dist/")) throw Error("uncompiled exports");
            console.log(`${p.name}@${p.version}: ${JSON.stringify(p.exports)}`);
        });'
    shasum -a 256 "$tarball"
done
cp "$SCRIPT_DIR/release-consumer.mjs" "$CONSUMER/smoke.mjs"
cp "$SCRIPT_DIR/release-consumer.mts" "$CONSUMER/consumer.mts"
cd "$CONSUMER"
npm init -y >/dev/null
npm install "$PACK_DIR"/*.tgz typescript @codemirror/state shiki@1.29.2
node smoke.mjs
npx -y node@20.10.0 smoke.mjs
npx tsc --noEmit --strict --module nodenext --moduleResolution nodenext \
    --skipLibCheck false --target es2022 --lib es2022,esnext.disposable,dom consumer.mts
# Web/schema/read advertise Node 20; highlight independently requires 20.10.
npx -y node@20.0.0 --input-type=module -e '
    import { s, edit } from "@sjon-lang/schema";
    import { read, readResult, fields } from "@sjon-lang/read";
    import { SjonEncoder, SjonReader } from "@sjon-lang/web";
    import { SjonHost } from "@sjon-lang/web/SjonHost";
    import "@sjon-lang/web/SjonSchemaBackend";
    import "@sjon-lang/web/createNodeFsResolver";
    const root = read("(a :k 1)")[0];
    if (root.tag !== "form" || root.span.start !== 0 || root.span.end !== 8) throw Error("read tree mismatch");
    const count = fields(root).get("k");
    if (count.tag !== "number" || count.value !== 1 || count.integer !== 1n) throw Error("read fields mismatch");
    if (readResult("(a :k 1)").diagnostics.length !== 0) throw Error("read diagnostics mismatch");
    const encoder = await SjonEncoder.load(`${process.env.SJON_WASM_DIR}/sjon.wasm`);
    const reader = await SjonReader.load(`${process.env.SJON_WASM_DIR}/sjon-binary.wasm`);
    if (reader.evalExprBinary(encoder.toBinary("(+ 1 2)")) !== 3) throw Error("eval mismatch");
    if (!encoder.applyEdit("(a :x 1)", edit.setKey([], "x", 2)).includes(":x 2")) throw Error("edit mismatch");
    console.log(`web/schema/read minimum-runtime smoke passed on ${process.version}`);
'
