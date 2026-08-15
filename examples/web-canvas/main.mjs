// Browser-ESM build of the web host, emitted by `zig build web-canvas`
// (runs `tsc -p hosts/web/tsconfig.browser.json` into hosts/web/dist/).
import { SjonEncoder } from "../../hosts/web/dist/sjon-reader.js";

const WASM_URL = new URL("../../zig-out/bin/sjon.wasm", import.meta.url);
const EMPTY = "(canvas :size [800 600] :rects [])";

const canvas = document.getElementById("c");
const ctx = canvas.getContext("2d");
const echo = document.getElementById("echo");

const wasmBytes = await fetch(WASM_URL).then((r) => {
    if (!r.ok) throw new Error(`fetch ${WASM_URL}: ${r.status}`);
    return r.arrayBuffer();
});
const enc = await SjonEncoder.loadFromBytes(wasmBytes);

let state = EMPTY;

function render() {
    const obj = enc.toJson(state, { mode: "compact" });
    ctx.clearRect(0, 0, canvas.width, canvas.height);
    for (const r of obj.rects ?? []) {
        const [cr, cg, cb, ca] = r.color;
        ctx.fillStyle = `rgba(${(cr * 255) | 0},${(cg * 255) | 0},${(cb * 255) | 0},${ca})`;
        ctx.fillRect(r.x, r.y, r.width, r.height);
    }
    echo.classList.remove("boot");
    echo.textContent = state;
}

canvas.addEventListener("click", () => {
    const w = (20 + Math.random() * 80) | 0;
    const h = (20 + Math.random() * 80) | 0;
    state = enc.applyEdit(state, {
        op: "insert_positional",
        path: ["rects"],
        value: {
            $form: "rect",
            x: (Math.random() * (canvas.width - w)) | 0,
            y: (Math.random() * (canvas.height - h)) | 0,
            width: w,
            height: h,
            color: [Math.random(), Math.random(), Math.random(), 0.7],
        },
    });
    render();
});

document.getElementById("export").addEventListener("click", () => {
    const blob = new Blob([state], { type: "application/sjon" });
    const a = document.createElement("a");
    a.href = URL.createObjectURL(blob);
    a.download = "canvas.sjon";
    a.click();
    URL.revokeObjectURL(a.href);
});

document.getElementById("import").addEventListener("change", async (e) => {
    const file = e.target.files[0];
    if (!file) return;
    const text = await file.text();
    const report = enc.validate(text);
    const parseErr = report.parse_diagnostics?.find((d) => d.severity === "err");
    if (parseErr) {
        alert(`Import failed: ${parseErr.message} (offset ${parseErr.span.start})`);
        e.target.value = "";
        return;
    }
    state = text;
    render();
    e.target.value = "";
});

document.getElementById("clear").addEventListener("click", () => {
    state = EMPTY;
    render();
});

render();
