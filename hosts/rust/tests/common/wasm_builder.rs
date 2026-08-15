//! Hand-assembled minimal v1-shaped WASM modules for pre-flight tests.
//! Two builders produce just enough bytes — three required function
//! exports plus `memory` — either to drive a specific ABI value or to
//! inject a forbidden import. Auto-size sections via `section()` so
//! off-by-one byte counts can't rot the fixtures (mirror of the JS
//! helpers in `hosts/web/test/host.test.ts`).

// Each test binary uses a different subset of helpers; see
// `tests/common/mod.rs` for the allow rationale. `expect_used` is
// silenced because every `.expect()` here documents a fixture-author
// invariant (LEB128 ranges) rather than a runtime fallible path.
#![allow(clippy::expect_used, clippy::unwrap_used, dead_code, unreachable_pub)]

const TYPE_FUNC: u8 = 0x60;
const KIND_FUNC: u8 = 0x00;
const KIND_MEMORY: u8 = 0x02;
const I32: u8 = 0x7f;
const I32_CONST: u8 = 0x41;
const END: u8 = 0x0b;
const MAGIC: [u8; 8] = [0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00];

/// Single-byte LEB128 — sufficient for the small values our test
/// fixtures encode (counts, function indices, single-byte ABI integers).
/// Takes `usize` so callers can pass `.len()` directly; the conversion
/// fails loudly if a fixture ever overflows the 7-bit range.
fn u(n: usize) -> Vec<u8> {
    let n: u8 = u8::try_from(n).expect("invariant: value out of single-byte LEB128 range");
    assert!(n <= 127, "u: {n} out of single-byte LEB128 range");
    vec![n]
}

/// Length-prefixed UTF-8 string with single-byte length.
fn lstr(s: &str) -> Vec<u8> {
    let bytes = s.as_bytes();
    let mut out = u(bytes.len());
    out.extend_from_slice(bytes);
    out
}

/// `[id, size, ...body]` with the size auto-computed from `body.len()`.
fn section(id: u8, body: Vec<u8>) -> Vec<u8> {
    let mut out = vec![id];
    out.extend(u(body.len()));
    out.extend(body);
    out
}

/// Vector of items: `[count, ...items]` with the count auto-computed.
fn vec_of(items: &[Vec<u8>]) -> Vec<u8> {
    let mut out = u(items.len());
    for it in items {
        out.extend_from_slice(it);
    }
    out
}

/// `(func (param ...) (result ...))` type entry.
fn func_type(params: &[u8], results: &[u8]) -> Vec<u8> {
    let mut out = vec![TYPE_FUNC];
    out.extend(u(params.len()));
    out.extend_from_slice(params);
    out.extend(u(results.len()));
    out.extend_from_slice(results);
    out
}

/// A function body — 0 locals + ops + end.
fn code(ops: &[u8]) -> Vec<u8> {
    let mut body = vec![0x00]; // 0 locals
    body.extend_from_slice(ops);
    body.push(END);
    let mut out = u(body.len());
    out.extend(body);
    out
}

fn cat(parts: &[&[u8]]) -> Vec<u8> {
    let mut out = Vec::new();
    for p in parts {
        out.extend_from_slice(p);
    }
    out
}

/// Build a minimal v1-shaped wasm module:
///   (memory (export "memory") 1)
///   (func (export "sjon_plugin_abi_version") (result i32) i32.const <abi>)
///   (func (export "sjon_plugin_alloc") (param i32) (result i32) i32.const 0)
///   (func (export "sjon_plugin_free") (param i32 i32))
#[allow(clippy::doc_markdown)]
pub fn build_stub_plugin_wasm(abi: u8) -> Vec<u8> {
    assert!(abi <= 63, "abi {abi} out of single-byte LEB128 range");
    let type_sec = section(
        0x01,
        vec_of(&[
            func_type(&[], &[I32]),
            func_type(&[I32], &[I32]),
            func_type(&[I32, I32], &[]),
        ]),
    );
    let func_sec = section(0x03, vec_of(&[u(0), u(1), u(2)]));
    let mem_sec = section(0x05, vec_of(&[cat(&[&[0x00], &u(1)])]));
    let export_sec = section(
        0x07,
        vec_of(&[
            cat(&[&lstr("memory"), &[KIND_MEMORY, 0x00]]),
            cat(&[&lstr("sjon_plugin_abi_version"), &[KIND_FUNC, 0x00]]),
            cat(&[&lstr("sjon_plugin_alloc"), &[KIND_FUNC, 0x01]]),
            cat(&[&lstr("sjon_plugin_free"), &[KIND_FUNC, 0x02]]),
        ]),
    );
    let code_sec = section(
        0x0a,
        vec_of(&[code(&[I32_CONST, abi]), code(&[I32_CONST, 0x00]), code(&[])]),
    );
    cat(&[
        &MAGIC,
        &type_sec,
        &func_sec,
        &mem_sec,
        &export_sec,
        &code_sec,
    ])
}

/// Build a wasm module with a forbidden `env.host_helper` import. The
/// import sits at func index 0, so the local funcs are 1, 2, 3 in the
/// export section.
pub fn build_import_forbidden_wasm() -> Vec<u8> {
    let type_sec = section(
        0x01,
        vec_of(&[
            func_type(&[I32], &[]),
            func_type(&[], &[I32]),
            func_type(&[I32], &[I32]),
            func_type(&[I32, I32], &[]),
        ]),
    );
    let import_sec = section(
        0x02,
        vec_of(&[cat(&[
            &lstr("env"),
            &lstr("host_helper"),
            &[KIND_FUNC, 0x00],
        ])]),
    );
    let func_sec = section(0x03, vec_of(&[u(1), u(2), u(3)]));
    let mem_sec = section(0x05, vec_of(&[cat(&[&[0x00], &u(1)])]));
    let export_sec = section(
        0x07,
        vec_of(&[
            cat(&[&lstr("memory"), &[KIND_MEMORY, 0x00]]),
            cat(&[&lstr("sjon_plugin_abi_version"), &[KIND_FUNC, 0x01]]),
            cat(&[&lstr("sjon_plugin_alloc"), &[KIND_FUNC, 0x02]]),
            cat(&[&lstr("sjon_plugin_free"), &[KIND_FUNC, 0x03]]),
        ]),
    );
    let code_sec = section(
        0x0a,
        vec_of(&[
            code(&[I32_CONST, 0x01]),
            code(&[I32_CONST, 0x00]),
            code(&[]),
        ]),
    );
    cat(&[
        &MAGIC,
        &type_sec,
        &import_sec,
        &func_sec,
        &mem_sec,
        &export_sec,
        &code_sec,
    ])
}
