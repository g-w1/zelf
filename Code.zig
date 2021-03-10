const main = @import("main.zig");
const cast = main.cast;

const std = @import("std");

const Code = @This();

output: []const u8,

pub fn deinit(self: Code, gpa: *std.mem.Allocator) void {
    gpa.free(self.output);
}

/// generate the assembly from the brainfuck input
/// ASSUMTIONS:
/// at the start of the code running,
/// dat_idx is r10,
pub fn gen(gpa: *std.mem.Allocator, bfsrc: []const u8) !Code {
    var code = std.ArrayList(u8).init(gpa);
    errdefer code.deinit();

    var loop_stack = std.ArrayList(u64).init(gpa);
    defer loop_stack.deinit();

    for (bfsrc) |c, i| {
        switch (c) {
            // inc dword [dat_idx]
            '+' => try code.appendSlice(&.{ 0x41, 0xff, 0x02 }),
            // dec dword qword [dat_idx]
            '-' => try code.appendSlice(&.{ 0x41, 0xff, 0x0a }),
            // add r10, 8
            '>' => try code.appendSlice(&.{ 0x49, 0x83, 0xc2, 0x08 }),
            // sub r10, 8
            '<' => try code.appendSlice(&.{ 0x49, 0x83, 0xea, 0x08 }),
            // write(1, dat_idx, 1)
            '.' => try write(&code),
            // read(0, dat_idx, 1)
            ',' => try read(&code),
            // NOP
            '[' => {
                // jumped to by the closing bracket
                try code.append(0x90);
                try loop_stack.append(code.items.len);
                // cmp QWORD PTR [r10],0x0
                try code.appendSlice(&.{
                    0x41, 0x83, 0x3a, 0x00,
                });
                // je <location of [
                try code.appendSlice(&.{
                    0x0f,
                    0x84,
                });
                // filled in by the closing bracket
                try code.appendSlice(&cast(@as(u32, 0)));
            },
            ']' => {
                const popped = loop_stack.popOrNull() orelse {
                    std.log.emerg("found a ] without a matching [: at index {d}", .{i});
                    std.process.exit(1);
                };
                // jmp <location of [
                try code.appendSlice(&.{
                    0xe9,
                });
                // heavy-lifting all the jump calculations
                const diff = code.items.len - popped;
                try code.appendSlice(cast(-1 * @intCast(i64, diff + 5))[0..4]);

                try code.append(0x90);
                std.mem.copy(u8, code.items[popped + 6 ..], &cast(@intCast(u32, code.items.len - popped - 10 - 1)));
            },
            else => {},
        }
    }
    if (loop_stack.items.len != 0) {
        std.log.emerg("found a [ without a matching ]", .{});
    }
    try exit0(&code);

    return Code{ .output = code.toOwnedSlice() };
}

fn exit0(c: *std.ArrayList(u8)) !void {
    try c.appendSlice(&.{
        0x48,
        0x31,
        0xff,
        0xb8,
        0x3c,
        0x00,
        0x00,
        0x00,
    });
    try syscall(c);
}

// TODO optimisation since all the things we store to 1 won't change
// just don't do them
fn read(c: *std.ArrayList(u8)) !void {
    // mov rax, 0
    try c.appendSlice(&.{
        0xb8,
        0x00,
        0x00,
        0x00,
        0x00,
    });
    // mov rdi, 1
    try c.appendSlice(&.{
        0xbf,
        0x01,
        0x00,
        0x00,
        0x00,
    });
    // mov rdx, 1
    try c.appendSlice(&.{
        0xba,
        0x01,
        0x00,
        0x00,
        0x00,
    });
    // mov rsi, r10
    try c.appendSlice(&.{
        0x4c,
        0x89,
        0xd6,
    });
    try syscall(c);
}
// TODO optimisation since all the things we store to 1 won't change
// just don't do them
fn write(c: *std.ArrayList(u8)) !void {
    // mov rax, 1
    try c.appendSlice(&.{
        0xb8,
        0x01,
        0x00,
        0x00,
        0x00,
    });
    // mov rdi, 1
    try c.appendSlice(&.{
        0xbf,
        0x01,
        0x00,
        0x00,
        0x00,
    });
    // mov rdx, 1
    try c.appendSlice(&.{
        0xba,
        0x01,
        0x00,
        0x00,
        0x00,
    });
    // mov rsi, r10
    try c.appendSlice(&.{
        0x4c,
        0x89,
        0xd6,
    });
    try syscall(c);
}

fn syscall(c: *std.ArrayList(u8)) !void {
    try c.appendSlice(&.{
        0x0f, 0x05,
    });
}
