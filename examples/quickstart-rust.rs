//! SJON quickstart — Rust consumer via wasmtime.
//!
//! This file is reference material. Drop it into a Cargo project that
//! depends on `sjon-host`:
//!
//! ```toml
//! [package]
//! name = "sjon-quickstart"
//! version = "0.0.0"
//! edition = "2024"
//!
//! [dependencies]
//! sjon-host = { path = "../sjon/hosts/rust" }
//! anyhow = "1"
//! ```
//!
//! Then build the SJON WASM artifact once (`zig build wasm-all` from
//! the SJON repo) and run `cargo run`.
//!
//! What it shows: load `sjon.wasm`, validate one small SJON document,
//! and print any diagnostics. See `hosts/rust/README.md` for the full
//! `SjonHost` surface.

use std::path::PathBuf;

use sjon_host::{HostOptions, SjonHost};

fn main() -> anyhow::Result<()> {
    // Adjust this to point at your local `zig-out/bin/sjon.wasm`.
    let wasm = PathBuf::from("../sjon/zig-out/bin/sjon.wasm");

    let mut host = SjonHost::load(&wasm, None)?;
    let source = r#"(scene :bpm 130 (canvas :name "main"))"#;
    let result = host.validate_document(source, &HostOptions::default())?;

    println!("source      : {source}");
    println!("diagnostics : {}", result.diagnostics.len());
    for d in &result.diagnostics {
        println!("  - {d:?}");
    }
    Ok(())
}
