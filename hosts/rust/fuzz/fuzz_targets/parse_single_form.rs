//! Fuzz target for `sjon_subset::parse_single_form` — the bootstrap
//! parser that walks `sjon-project.sjon` and manifest files *before*
//! `sjon.wasm` is loaded. Attacker-influenced bytes flow through here
//! every time `FilesystemResolver::build` runs, so the never-panic
//! contract matters even though the parser itself is small.
//!
//! Run with:
//!
//!   cd hosts/rust && cargo +nightly fuzz run parse_single_form -- -max_total_time=60
//!
//! The seed corpus under `fuzz/corpus/parse_single_form/` is the
//! `sjon-project.sjon` files from the conformance suite — they're
//! free-to-reuse fixtures and give libfuzzer a head start over random
//! bytes.

#![no_main]

use libfuzzer_sys::fuzz_target;

fuzz_target!(|data: &[u8]| {
    let Ok(s) = std::str::from_utf8(data) else {
        return;
    };
    let _ = sjon_host::__fuzz_only::parse_single_form(s);
});
