const std = @import("std");
pub const base_point: u64 = 0x200000;
const prologue_len = 10;

const Code = @import("Code.zig");

const number_sections: u16 = 5;
pub fn cast(i: anytype) [@sizeOf(@TypeOf(i))]u8 {
    return @bitCast([@sizeOf(@TypeOf(i))]u8, i);
}
const help =
    \\bz - brainfuck to elf compiler in zig
    \\Usage:
    \\bz [file]
    \\options:
    \\-o [file to output] (default "a.out")
    \\-h, --help | show this help text
    \\-b [size of brainfuck array] (default 30_000)
    \\
;

pub fn main() !void {
    var general_pa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = general_pa.deinit();
    const gpa = &general_pa.allocator;
    var output: ?[]const u8 = null;
    var input: ?[]const u8 = null;
    var bss_size: ?u32 = null;
    {
        var i: usize = 1;
        const argv = std.os.argv;
        while (i < argv.len) : (i += 1) {
            const arg = argv[i];
            if (std.mem.eql(u8, std.mem.spanZ(arg), "-o")) {
                if (output != null)
                    fatal("cannot have -o more than once");
                if (i + 1 == argv.len)
                    fatal("expected another argument after -o");
                i += 1;
                output = std.mem.spanZ(argv[i]);
            } else if (std.mem.eql(u8, std.mem.spanZ(arg), "-h") or std.mem.eql(u8, std.mem.spanZ(arg), "--help")) {
                const stdout = std.io.getStdOut();
                try stdout.writeAll(help);
                std.process.exit(0);
            } else if (std.mem.eql(u8, std.mem.spanZ(arg), "-b")) {
                if (bss_size != null)
                    fatal("cannot have -b more than once");
                if (i + 1 == argv.len)
                    fatal("expected another argument after -b");
                i += 1;
                bss_size = std.fmt.parseUnsigned(u32, std.mem.spanZ(argv[i]), 10) catch {
                    fatal("unable to parse argument after -b");
                };
            } else {
                if (input != null)
                    fatal("cannot have more than 1 input file");
                input = std.mem.spanZ(argv[i]);
            }
        }
        if (input == null) {
            fatal("need one input file\n" ++ help);
        }
    }
    const bfcode = try std.fs.cwd().readFileAlloc(gpa, input.?, std.math.maxInt(usize));
    defer gpa.free(bfcode);
    try genElfAndWriteToFs(gpa, bfcode, .{ .output_name = output });
}

fn fatal(comptime msg: []const u8) noreturn {
    std.log.emerg(msg, .{});
    std.process.exit(1);
}

const ElfOpts = struct {
    bss_len: u16 = 30_000,
    output_name: ?[]const u8,
};
fn genElfAndWriteToFs(gpa: *std.mem.Allocator, bfcode: []const u8, opts: ElfOpts) !void {
    var dat = std.ArrayList(u8).init(gpa);
    defer dat.deinit();

    // === the code
    const genned = try Code.gen(gpa, bfcode);
    defer genned.deinit(gpa);
    const data = "";
    const shstrtab = "\x00.text\x00.data\x00.shstrtab\x00.bss\x00";

    const genned_len = prologue_len + genned.output.len;
    // zeros are for the prologue after we figure out the spacing
    const c = try std.mem.concat(gpa, u8, &.{ &[_]u8{0} ** prologue_len, genned.output, data, shstrtab });
    defer gpa.free(c);

    // === our elf linking
    const header_off = getSize(ElfHeader) + getSize(ProgHeader);
    const entry_off = base_point + header_off;
    const genned_o = header_off;
    const data_o = header_off + genned_len;
    const shstrtab_o = data_o + data.len;
    const bss_o = shstrtab_o + shstrtab.len;
    const sections_off = header_off + c.len;
    const sh_size = number_sections * getSize(SectionHeader);
    const sh_off = sections_off + sh_size;
    const filesize = sh_off;
    {
        // doing some ad-hoc relocations for the prologue
        std.mem.copy(u8, c[0..2], &.{ 0x49, 0xba });
        std.mem.copy(u8, c[2..prologue_len], &cast(bss_o + base_point));
    }

    // ELF HEADER
    try writeTypeToCode(&dat, ElfHeader, .{
        .e_entry = cast(entry_off),
        .e_shoff = cast(sections_off),
        .e_shnum = cast(number_sections),
        .e_shstrndx = cast(@as(u16, 3)),
    });

    // PROGRAM HEADERS
    try writeTypeToCode(&dat, ProgHeader, .{
        .p_filesz = cast(filesize),
        .p_memsz = cast(filesize),
        .p_offset = .{0} ** 8,
    });

    // all the sections

    try dat.appendSlice(c);

    // OUR SECTION HEADERS
    // the null section header
    try writeTypeToCode(&dat, SectionHeader, .{
        .sh_name = cast(@as(u32, 0)),
        .sh_type = cast(SHT_NOBITS),
        .sh_flags = cast(@as(u64, 0)),
        .sh_addr = cast(@as(u64, 0)),
        .sh_offset = cast(@as(u64, 0)),
        .sh_size = cast(@as(u64, 0)),
        .sh_link = cast(@as(u32, 0)),
        .sh_info = cast(@as(u32, 0)),
        .sh_addralign = cast(@as(u64, 0)),
        .sh_entsize = cast(@as(u64, 0)),
    });
    // .text
    const text_off = @truncate(u32, std.mem.indexOf(u8, shstrtab, ".text").?);
    try writeTypeToCode(&dat, SectionHeader, .{
        .sh_name = cast(@truncate(u32, text_off)),
        .sh_type = cast(SHT_PROGBITS),
        .sh_flags = cast(@as(u64, 0)),
        .sh_addr = cast(@as(u64, base_point + genned_o)),
        .sh_offset = cast(@as(u64, genned_o)),
        .sh_size = cast(@as(u64, genned_len)),
        .sh_link = cast(@as(u32, 0)),
        .sh_info = cast(@as(u32, 0)),
        .sh_addralign = cast(@as(u64, 0)),
        .sh_entsize = cast(@as(u64, 0)),
    });
    // .data
    const data_off = @truncate(u32, std.mem.indexOf(u8, shstrtab, ".data").?);
    try writeTypeToCode(&dat, SectionHeader, .{
        .sh_name = cast(@truncate(u32, data_off)),
        // TODO find right sh_type for this
        .sh_type = cast(SHT_PROGBITS),
        .sh_flags = cast(@as(u64, 0)),
        .sh_addr = cast(base_point + data_o),
        .sh_offset = cast(data_o),
        .sh_size = cast(@as(u64, data.len)),
        .sh_link = cast(@as(u32, 0)),
        .sh_info = cast(@as(u32, 0)),
        .sh_addralign = cast(@as(u64, 0)),
        .sh_entsize = cast(@as(u64, 0)),
    });
    // .shstrtab
    const shstrtab_off = @truncate(u32, std.mem.indexOf(u8, shstrtab, ".shstrtab").?);
    try writeTypeToCode(&dat, SectionHeader, .{
        .sh_name = cast(@truncate(u32, shstrtab_off)),
        .sh_type = cast(SHT_STRTAB),
        .sh_flags = cast(@as(u64, 0)),
        .sh_addr = cast(@as(u64, base_point + shstrtab_o)),
        .sh_offset = cast(@as(u64, shstrtab_o)),
        .sh_size = cast(@as(u64, shstrtab.len)),
        .sh_link = cast(@as(u32, 0)),
        .sh_info = cast(@as(u32, 0)),
        .sh_addralign = cast(@as(u64, 0)),
        .sh_entsize = cast(@as(u64, 0)),
    });
    // .bss
    const bss_off = @truncate(u32, std.mem.indexOf(u8, shstrtab, ".bss").?);
    try writeTypeToCode(&dat, SectionHeader, .{
        .sh_name = cast(@truncate(u32, bss_off)),
        .sh_type = cast(SHT_NOBITS),
        .sh_flags = cast(@as(u64, 0)),
        .sh_addr = cast(@as(u64, base_point + bss_o)),
        .sh_offset = cast(@as(u64, bss_o)),
        .sh_size = cast(@as(u64, opts.bss_len)),
        .sh_link = cast(@as(u32, 0)),
        .sh_info = cast(@as(u32, 0)),
        .sh_addralign = cast(@as(u64, 0)),
        .sh_entsize = cast(@as(u64, 0)),
    });

    // === write to filesystem

    var name: []const u8 = "a.out";
    if (opts.output_name) |n| name = n;
    const file = try std.fs.cwd().createFile(name, .{
        .mode = 0o777,
    });
    defer file.close();
    _ = try file.write(dat.items);
}

fn writeTypeToCode(c: *std.ArrayList(u8), comptime T: type, s: T) !void {
    inline for (std.meta.fields(T)) |f| {
        switch (f.field_type) {
            u8 => try c.append(@field(s, f.name)),
            else => try c.appendSlice(&@field(s, f.name)),
        }
    }
}

fn getSize(comptime t: type) usize {
    comptime {
        var i: usize = 0;
        inline for (std.meta.fields(t)) |f| {
            i += @sizeOf(f.field_type);
        }
        return i;
    }
}

const ElfHeader = struct {
    /// e_ident
    magic: [4]u8 = "\x7fELF".*,
    /// 32 bit (1) or 64 (2)
    class: u8 = 2,
    /// endianness little (1) or big (2)
    endianness: u8 = 1,
    /// elf version
    version: u8 = 1,
    /// osabi: we want systemv which is 0
    abi: u8 = 0,
    /// abiversion: 0
    abi_version: u8 = 0,
    /// paddding
    padding: [7]u8 = [_]u8{0} ** 7,

    /// object type
    e_type: [2]u8 = cast(@as(u16, 2)),

    /// arch
    e_machine: [2]u8 = cast(@as(u16, 0x3e)),

    /// version
    e_version: [4]u8 = cast(@as(u32, 1)),

    /// entry point
    e_entry: [8]u8,

    /// start of program header
    /// It usually follows the file header immediately,
    /// making the offset 0x34 or 0x40
    /// for 32- and 64-bit ELF executables, respectively.
    e_phoff: [8]u8 = cast(@as(u64, 0x40)),

    /// e_shoff
    /// start of section header table
    e_shoff: [8]u8,

    /// ???
    e_flags: [4]u8 = .{0} ** 4,

    /// Contains the size of this header,
    /// normally 64 Bytes for 64-bit and 52 Bytes for 32-bit format.
    e_ehsize: [2]u8 = cast(@as(u16, 0x40)),

    /// size of program header
    e_phentsize: [2]u8 = cast(@as(u16, 56)),

    /// number of entries in program header table
    e_phnum: [2]u8 = cast(@as(u16, 1)),

    /// size of section header table entry
    e_shentsize: [2]u8 = cast(@as(u16, 0x40)),

    /// number of section header entries
    e_shnum: [2]u8,

    /// index of section header table entry that contains section names (.shstrtab)
    e_shstrndx: [2]u8,
};

const PF_X = 0x1;
const PF_W = 0x2;
const PF_R = 0x4;

const ProgHeader = struct {
    /// type of segment
    /// 1 for loadable
    p_type: [4]u8 = cast(@as(u32, 1)),

    /// segment dependent
    /// NO PROTECTION
    p_flags: [4]u8 = cast(@as(u32, PF_R | PF_W | PF_X)),

    /// offset of the segment in the file image
    p_offset: [8]u8,

    /// virtual addr of segment in memory. start of this segment
    p_vaddr: [8]u8 = cast(@as(u64, base_point)),

    /// same as vaddr except on physical systems
    p_paddr: [8]u8 = cast(@as(u64, base_point)),

    p_filesz: [8]u8,

    p_memsz: [8]u8,

    /// 0 and 1 specify no alignment.
    /// Otherwise should be a positive, integral power of 2,
    /// with p_vaddr equating p_offset modulus p_align.
    p_align: [8]u8 = cast(@as(u64, 0x100)),
};

const SHT_NOBITS: u32 = 8;
const SHT_NULL: u32 = 0;
const SHT_PROGBITS: u32 = 1;
const SHT_STRTAB: u32 = 3;

const SectionHeader = struct {
    /// offset into .shstrtab that contains the name of the section
    sh_name: [4]u8,

    /// type of this header
    sh_type: [4]u8,

    /// attrs of the section
    sh_flags: [8]u8,

    /// virtual addr of section in memory
    sh_addr: [8]u8,

    /// offset in file image
    sh_offset: [8]u8,

    /// size of section in bytes (0 is allowed)
    sh_size: [8]u8,

    /// section index
    sh_link: [4]u8,

    /// extra info abt section
    sh_info: [4]u8,

    /// alignment of section (power of 2)
    sh_addralign: [8]u8,

    /// size of bytes of section that contains fixed-size entry otherwise 0
    sh_entsize: [8]u8,
};
