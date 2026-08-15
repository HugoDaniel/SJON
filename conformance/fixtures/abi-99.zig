//! Conformance fixture — a v2-shaped plugin binary that reports ABI
//! version 99. Drives the `plugin-exec-abi-mismatch` corpus case: the
//! Web + Rust hosts instantiate, call `sjon_plugin_abi_version()`, see
//! a non-2 result, and surface `plugin_abi_mismatch`.
//!
//! Built by the top-level `plugin-fixtures` build step into
//! `conformance/cases/plugin-exec-abi-mismatch/manifests/shapes.wasm`
//! (the resolver pairs `shapes.sjon` with `shapes.wasm`). Standalone
//! enough that an authoring SDK isn't needed — just the three required
//! v2 standard exports and an empty import set.

export fn sjon_plugin_abi_version() callconv(.c) u32 {
    return 99;
}

export fn sjon_plugin_alloc(len: u32) callconv(.c) ?[*]u8 {
    _ = len;
    return null;
}

export fn sjon_plugin_free(ptr: ?[*]u8, len: u32) callconv(.c) void {
    _ = ptr;
    _ = len;
}
