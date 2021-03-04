const Builder = @import("std").build.Builder;

pub fn build(b: *Builder) !void {
    // Standard target options allows the person running `zig build` to choose
    // what target to build for. Here we do not override the defaults, which
    // means any target is allowed, and the default is native. Other options
    // for restricting supported target set are available.
    const target = b.standardTargetOptions(.{});

    // Standard release options allow the person running `zig build` to select
    // between Debug, ReleaseSafe, ReleaseFast, and ReleaseSmall.
    const mode = b.standardReleaseOptions();

    const exe = b.addExecutable("elfplay", "main.zig");
    exe.setTarget(target);
    exe.setBuildMode(mode);
    exe.install();

    _ = try b.exec(&.{ "nasm", "-fbin", "-otiny", "elf.asm" });
    _ = try b.exec(&.{ "chmod", "+x", "tiny" });
    _ = try b.exec(&.{ "nasm", "-felf64", "hello.asm", "-ohello.o" });
    _ = try b.exec(&.{ "ld", "-ohello", "hello.o" });

    const run_cmd = exe.run();
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    b.getInstallStep().dependOn(&run_cmd.step);
}
