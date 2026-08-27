//! Standalone build script for the `double` plugin fixture.
//!
//! The repo's top-level `build.zig` already wires a `plugin-fixtures` step
//! that builds and stages `double.wasm` next to this file. This script
//! mirrors that build so the plugin example can also be built in isolation
//! (`zig build --build-file examples/plugins/double/build.zig`), useful as
//! a copy-and-paste seed for downstream plugin authors who don't want to
//! reach into the SJON tree.

const std = @import("std");

pub fn build(b: *std.Build) void {
    const wasm_target = b.resolveTargetQuery(.{
        .cpu_arch = .wasm32,
        .os_tag = .freestanding,
    });

    const wasm = b.addExecutable(.{
        .name = "double",
        .root_module = b.createModule(.{
            .root_source_file = b.path("double.zig"),
            .target = wasm_target,
            .optimize = .ReleaseSmall,
        }),
    });
    wasm.entry = .disabled;
    wasm.rdynamic = true;

    b.installArtifact(wasm);
}
