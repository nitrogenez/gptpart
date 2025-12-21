// Copyright (c) 2025 nitrogenez. All Rights Reserved.

const std = @import("std");
const gpt = @import("gpt.zig");

test {
    _ = gpt;
}

const assert = std.debug.assert;
const print = std.debug.print;

pub const types = @import("types.zig");

pub const gpt_pmbr_lba = 0;
pub const gpt_header_lba = 1;
pub const gpt_array_lba = 2;

pub const pmbr_signature = 0xaa55;
pub const pmbr_ostype_efi = 0xEF;
pub const pmbr_ostype_efi_gpt = 0xEE;

pub const gpt_header_signature = "EFI PART";
pub const gpt_header_signature_int = 0x5452415020494645;
pub const gpt_header_revision = 0x00010000;
pub const gpt_min_reserved = 16384;

pub const gpt_header_size = 92;
pub const gpt_array_entry_size = 128;
pub const gpt_array_entry_count = 128;

pub const gpt_ent_attr_platform = (1 << 0);
pub const gpt_ent_attr_efi = (1 << 1);
pub const gpt_ent_attr_bootable = (1 << 2);
pub const gpt_ent_attr_bootme = (1 << 59);
pub const gpt_ent_attr_bootonce = (1 << 58);
pub const gpt_ent_attr_bootfailed = (1 << 57);

pub const Partition = struct {
    name: []const u8,
    start: usize,
    end: usize,
    attr: u64 = 0,
    type: std.os.uefi.Guid = types.linux_data,

    pub fn init(type_guid: std.os.uefi.Guid, start: usize, end: usize, name: []const u8) Partition {
        return .{
            .name = name,
            .start = start,
            .end = end,
            .type = type_guid,
            .attr = 0,
        };
    }

    /// Check whether or not the partition `self` overlaps partition `other`.
    pub inline fn overlaps(self: Partition, other: Partition) bool {
        return (self.start >= other.start and self.start <= other.end) or
            (self.end >= other.start and self.end <= other.end);
    }

    /// Check whether or not the partition `self` is in bounds from `start` to `end`.
    pub inline fn overlapsRange(self: Partition, start: usize, end: usize) bool {
        return (self.start >= start and self.start <= end) or (self.end >= start and self.end <= end);
    }

    /// Check whether or not the partition `self` overlaps any partitions from the `list`.
    pub fn overlapsAny(self: Partition, list: []const Partition) bool {
        return for (list) |entry| {
            if (self.overlaps(entry)) break true;
        } else false;
    }

    /// Returns the size of partition `self`.
    pub fn getSize(self: Partition) usize {
        return self.end - self.start;
    }

    pub fn getByteSize(self: Partition, sector_size: usize) usize {
        return (self.end - self.start) * sector_size;
    }

    /// Checks whether or not the partition "fits", basically if it's size is less than `size`.
    pub fn fits(self: Partition, size: usize) bool {
        return self.getSize() <= size;
    }
};

/// The disk. Basically it's only purpose is to store the sector count and sector size.
/// `sector_size` should be 512, 2048, or 4096, but you can do whatever, see if it breaks anything :)
pub const Disk = struct {
    sectors: usize,
    sector_size: usize,

    pub fn init(size: usize, sector_size: usize) !Disk {
        const secs = size / sector_size;
        if (secs <= (gpt_min_reserved * 2) + sector_size * 4)
            return error.DiskTooSmall;
        return .{ .sectors = secs, .sector_size = sector_size };
    }

    pub inline fn getSize(self: Disk) usize {
        return self.sectors * self.sector_size;
    }

    /// Returns the size of a GPT label in bytes. This includes the PMBR, the GPT header, and the partition entry array.
    pub fn getLabelSize(self: Disk) usize {
        return (gpt.getFirstUsableSector(self.sector_size) - 1) * self.sector_size;
    }

    pub fn getLabelSectors(self: Disk) usize {
        return gpt.getFirstUsableSector(self.sector_size) - 1;
    }

    pub fn getLabelOffset(self: Disk) usize {
        return self.getLabelSize() + 1;
    }

    pub fn getLabelSectorOffset(self: Disk) usize {
        return self.getLabelSectors() + 1;
    }

    pub fn mib(self: Disk, n: usize) usize {
        return self.getLabelSize() + (n * 1024 * 1024); 
    }

    pub const default: Disk = .{
        .sector_size = 512,
        .sectors = 512,
    };
};

pub const PartitionTable = struct {
    inner: std.ArrayListUnmanaged(Partition) = .empty,

    pub fn deinit(self: *PartitionTable, allocator: std.mem.Allocator) void {
        self.inner.deinit(allocator);
        self.* = undefined;
    }

    /// Append to the partition table. Checks if the `partition` overlaps any other,
    /// existing partition or if it overlaps the GPT label itself.
    /// Returns the index of the appended partition on success, or error.PartitionOverlap/LabelOverlap.
    pub fn append(self: *PartitionTable, allocator: std.mem.Allocator, disk: Disk, partition: Partition) !usize {
        // Partition table overlap check
        if (partition.overlapsAny(self.inner.items))
            return error.PartitionOverlap;
        // Label overlap check
        if (partition.overlapsRange(0, disk.getLabelSectors()))
            return error.LabelOverlap;
        // Size check
        if (!partition.fits(disk.getSize()))
            return error.PartitionTooBig;

        return try self.appendUnchecked(allocator, partition);
    }

    pub fn appendUnchecked(self: *PartitionTable, allocator: std.mem.Allocator, partition: Partition) !usize {
        try self.inner.append(allocator, partition);
        return self.inner.items.len;
    }

    pub fn getGptEntries(self: PartitionTable, gpa: std.mem.Allocator) ![]const gpt.Ent {
        var entries: std.ArrayListUnmanaged(gpt.Ent) = .empty;
        for (self.inner.items) |entry| {
            var r_ent: gpt.Ent = .{
                .ent_type = entry.type,
                .guid = getRandomGuid(),
                .lba_start = entry.start,
                .lba_end = entry.end,
                .attr = entry.attr,
            };
            _ = try std.unicode.utf8ToUtf16Le(&r_ent.name, entry.name);
            try entries.append(gpa, r_ent);
        }
        return entries.toOwnedSlice(gpa);
    }

    pub fn commit(self: PartitionTable, gpa: std.mem.Allocator, disk: Disk, file: anytype) ![]const gpt.Ent {
        const gpt_ents: []const gpt.Ent = try self.getGptEntries(gpa);
        try gpt.write(disk.sectors, disk.sector_size, gpt_ents, file);
        return gpt_ents;
    }

    pub const empty: PartitionTable = .{};
};

pub fn getRandomGuid() std.os.uefi.Guid {
    var buf: std.os.uefi.Guid = .{
        .time_low = std.crypto.random.int(u32),
        .time_mid = std.crypto.random.int(u16),
        .time_high_and_version = std.crypto.random.int(u16),
        .clock_seq_high_and_reserved = std.crypto.random.int(u8),
        .clock_seq_low = std.crypto.random.int(u8),
        .node = undefined,
    };
    std.crypto.random.bytes(&buf.node);
    return buf;
}

test "Basic partition" {
    const disk: Disk = try .init(32 * 1024 * 1024, 512);
    const file = try std.fs.cwd().createFile("disk.img", .{ .truncate = true });
    defer file.close();

    try file.seekTo(disk.getSize() - 1);
    try file.writeAll("\x00");

    var pt: PartitionTable = .empty;
    defer pt.deinit(std.testing.allocator);

    _ = try pt.append(std.testing.allocator, disk, .{
        .name = "efi",
        .start = gpt.alignOptimal(disk.mib(1) / disk.sector_size),
        .end = gpt.alignOptimal(disk.mib(15) / disk.sector_size),
        .type = types.efi,
    });
    _ = try pt.append(std.testing.allocator, disk, .{
        .name = "root",
        .start = gpt.alignOptimal(disk.mib(16) / disk.sector_size),
        .end = gpt.alignOptimal(disk.mib(30) / disk.sector_size),
    });
    const ents = try pt.commit(std.testing.allocator, disk, file);
    defer std.testing.allocator.free(ents);
}
