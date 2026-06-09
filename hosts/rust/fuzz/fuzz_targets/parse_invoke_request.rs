//! Fuzz target for `wasm::parse_invoke_request` — the binary-frame
//! decoder the wasmtime `env.sjon_host_invoke_plugin` callback runs on
//! every D7-exec plugin call. Attacker-influenced bytes here originate
//! from the plugin invoker inside `sjon.wasm` and flow back through
//! the host without re-validation, so the never-panic contract must
//! survive truncation, oversized length prefixes, and non-UTF-8 names.
//!
//! Run with:
//!
//!   cd hosts/rust && cargo +nightly fuzz run parse_invoke_request -- -max_total_time=60
//!
//! The seed corpus under `fuzz/corpus/parse_invoke_request/` starts
//! empty; libfuzzer discovers the framing structure from coverage
//! feedback. Seed with a real invoke-request capture if coverage
//! plateaus.

#![no_main]

use libfuzzer_sys::fuzz_target;

fuzz_target!(|data: &[u8]| {
    let _ = sjon_host::__fuzz_only::parse_invoke_request(data);
});
