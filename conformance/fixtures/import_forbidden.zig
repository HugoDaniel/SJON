extern "env" fn host_helper(p: u32) callconv(.c) void;

export fn sjon_plugin_abi_version() callconv(.c) u32 {
    return 1;
}

export fn sjon_plugin_alloc(len: u32) callconv(.c) ?[*]u8 {
    host_helper(len);
    return null;
}

export fn sjon_plugin_free(ptr: ?[*]u8, len: u32) callconv(.c) void {
    _ = ptr;
    _ = len;
}
