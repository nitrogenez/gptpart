// Copyright (c) 2025 nitrogenez. All Rights Reserved.

const std = @import("std");
const root = @import("root.zig");

pub const Chs = extern struct {
    cylinder: u8,
    head: u8,
    sector: u8,
};

pub const Record = extern struct {
    status: u8,
    first_sector: Chs,
    part_type: u8,
    last_sector: Chs,
    start_lba: u32,
    sectors: u32,

    pub const empty: Record = std.mem.zeroes(Record);
};

pub const Hdr = extern struct {
    disk_sig: u32,
    __reserved: u16 = 0,
    record_1: Record,
    record_2: Record,
    record_3: Record,
    record_4: Record,
    mbr_sig: u16 = root.pmbr_signature,
};

pub const BootCode = [440]u8;

pub const protective: Hdr = .{
    .disk_sig = 0,
    .record_1 = .{
        .status = 0x00,
        .first_sector = .{
            .cylinder = 0x00,
            .head = 0x02,
            .sector = 0x00,
        }, 
        .part_type = root.pmbr_ostype_efi_gpt,
        .last_sector = .{
            .cylinder = 0xFF,
            .head = 0xFF,
            .sector = 0xFF,
        },
        .start_lba = 1,
        .sectors = 0xFFFFFFFF,
    },
    .record_2 = .empty,
    .record_3 = .empty,
    .record_4 = .empty,
};

pub fn writeProtective(file: anytype) !void {
    try file.seekTo(0);
    try file.seekBy(438);
    try file.writeAll(std.mem.asBytes(&protective));
} 
