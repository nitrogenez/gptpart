// Copyright (c) 2025 nitrogenez. All Rights Reserved.

const std = @import("std");
const root = @import("root.zig");
const mbr = @import("mbr.zig");

pub const Hdr = extern struct {
    signature: u64 = root.gpt_header_signature_int,
    revision: u32 = root.gpt_header_revision,
    size: u32 = root.gpt_header_size,
    crc_self: u32 = 0,
    __reserved: u32 = 0,
    lba_self: u64 = root.gpt_header_lba,
    lba_alt: u64,
    lba_start: u64,
    lba_end: u64,
    guid: std.os.uefi.Guid,
    lba_table: u64 = root.gpt_array_lba,
    entries: u32 = root.gpt_array_entry_count,
    entsize: u32 = root.gpt_array_entry_size,
    crc_table: u32 = 0,
};

pub const Ent = extern struct {
    ent_type: std.os.uefi.Guid,
    guid: std.os.uefi.Guid,
    lba_start: u64,
    lba_end: u64,
    attr: u64,
    name: [36]u16 = std.mem.zeroes([36]u16),
};

pub fn getFirstUsableSector(secsz: usize) usize {
    const pea_secs = (root.gpt_array_entry_size * root.gpt_array_entry_count) / secsz;
    const hdr_secs = 2;
    return pea_secs + hdr_secs + 1;
}

pub fn alignOptimal(lba: usize) usize {
    return std.mem.alignForward(usize, lba, 2048);
}

pub fn write(secs: usize, secsz: usize, ents: []const Ent, file: anytype) !void {
    const pea_secs = (root.gpt_array_entry_size * root.gpt_array_entry_count) / secsz;
    const hdr_alt_lba = secs - 1;
    const pea_alt_lba = hdr_alt_lba - pea_secs;

    if ((pea_secs + 2) * 2 >= secs)
        return error.DiskTooSmall;

    if (root.gpt_header_lba >= hdr_alt_lba)
        return error.BackupTooEarly;

    try mbr.writeProtective(file);

    const pea_bytes = std.mem.sliceAsBytes(ents);
    var pea_buf = std.mem.zeroes([root.gpt_array_entry_count * root.gpt_array_entry_size]u8);
    @memcpy(pea_buf[0..pea_bytes.len], pea_bytes);
    const pea_checksum = std.hash.Crc32.hash(pea_buf[0..]);

    try file.seekTo(root.gpt_array_lba * secsz);
    try file.writeAll(pea_bytes);

    try file.seekTo(pea_alt_lba * secsz);
    try file.writeAll(pea_bytes);

    var hdr: Hdr = .{
        .guid = root.getRandomGuid(),
        .crc_table = pea_checksum,
        .lba_alt = hdr_alt_lba,
        .lba_start = pea_secs + root.gpt_header_lba + 1,
        .lba_end = pea_alt_lba - 1,
    };
    hdr.crc_self = std.hash.Crc32.hash(std.mem.asBytes(&hdr)[0..root.gpt_header_size]);

    try file.seekTo(root.gpt_header_lba * secsz);
    try file.writeAll(std.mem.asBytes(&hdr));

    hdr.lba_self = hdr_alt_lba;
    hdr.lba_alt = root.gpt_header_lba;
    hdr.lba_table = pea_alt_lba;
    hdr.crc_self = 0;
    hdr.crc_self = std.hash.Crc32.hash(std.mem.asBytes(&hdr)[0..root.gpt_header_size]);

    try file.seekTo(hdr.lba_self * secsz);
    try file.writeAll(std.mem.asBytes(&hdr));
}

test "basic write" {
    const secsz = 512;
    const size = 32 * 1024 * 1024;
    const secs = size / secsz;
    const file = try std.fs.cwd().createFile("disk-basic-write.img", .{ .truncate = true });
    defer file.close();

    try file.seekTo(size - 1);
    try file.writeAll("\x00");

    const first_lba = getFirstUsableSector(secsz);
    const efi_start = alignOptimal(first_lba);
    const efi_end = alignOptimal(efi_start + 4) - 1;
    const root_start = alignOptimal(efi_end + 1);
    const root_end = alignOptimal(root_start + 4) - 1;
    const efi_name = std.unicode.utf8ToUtf16LeStringLiteral("efi");
    const root_name = std.unicode.utf8ToUtf16LeStringLiteral("root");

    var efi_ent = Ent{
        .name = undefined,
        .attr = 0,
        .ent_type = root.types.efi,
        .guid = root.getRandomGuid(),
        .lba_start = efi_start,
        .lba_end = efi_end,
    };
    var root_ent = Ent{
        .name = undefined,
        .attr = 0,
        .ent_type = root.types.linux_data,
        .guid = root.getRandomGuid(),
        .lba_start = root_start,
        .lba_end = root_end,
    };
    @memcpy(efi_ent.name[0..efi_name.len], efi_name);
    @memcpy(root_ent.name[0..root_name.len], root_name);
    try write(secs, secsz, &.{ efi_ent, root_ent }, file);
}
