//! Single source of truth for the SJON semantic version.
//!
//! Imported from `root.zig` (re-exported as `sjon.version`), `wasm.zig`,
//! and `wasm_binary.zig` (the read-only artifact intentionally does NOT
//! import `root.zig`, so we keep the constant in this leaf file to
//! avoid version-string drift across the three describe outputs).

pub const string = "1.1.0";
