//! Conformance fixture — a v1-shaped plugin binary that declares a
//! forbidden `env.host_helper` import. Drives the
//! `plugin-exec-import-forbidden` corpus case: the Web + Rust hosts'
//! pre-flight rejects non-empty import sets with
//! `plugin_import_forbidden` at the `(use-plugin …)` span.
//!
//! Built by the top-level `plugin-fixtures` build step into
//! `conformance/cases/plugin-exec-import-forbidden/manifests/forbidden.wasm`.

extern "env" fn host_helper(p: u32) callconv(.c) void;

export fn sjon_plugin_abi_version() callconv(.c) u32 {
    return 1;
}

export fn sjon_plugin_alloc(len: u32) callconv(.c) ?[*]u8 {
    // Call the import so the linker keeps it in the module's import
    // section — without this reference, dead-code elimination would
    // drop the import and pre-flight would see an empty import set.
    host_helper(len);
    return null;
}

export fn sjon_plugin_free(ptr: ?[*]u8, len: u32) callconv(.c) void {
    _ = ptr;
    _ = len;
}
