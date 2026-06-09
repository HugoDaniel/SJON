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
