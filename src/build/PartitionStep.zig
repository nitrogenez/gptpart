// Copyright (c) 2025 nitrogenez. All Rights Reserved.

//! This step is mainly targeted at the lumi project.
//! `PartitionStep` is a zig build system addon to create
//! GPT-partitioned disks at build time. The main focus
//! is hobbyist OS development, making the process of
//! boot media setup a little bit easier.
//!
//! NOTE: This is not intended to be used outside of `build.zig`.

const std = @import("std");
const root = @import("../root.zig");

step: std.Build.Step,
output: std.Build.GeneratedFile,
table: root.PartitionTable,
disk: root.Disk,
basename: []const u8,

pub fn create(b: *std.Build, size: usize, sector_size: usize, basename: []const u8) *@This() {
    const self: *@This() = b.allocator.create(@This()) catch @panic("OOM");

    self.* = .{
        .step = .init(.{
            .id = .custom,
            .name = "Partition disk image",
            .owner = b,
            .makeFn = make,
        }),
        .output = .{ .step = &self.step },
        .basename = basename,
        .disk = root.Disk.init(size, sector_size) catch @panic("Disk creation error"),
        .table = .empty,
    };
    return self;
}

pub fn addPart(self: *@This(), part: root.Partition) !void {
    _ = try self.table.append(self.step.owner.allocator, self.disk, part);
}

pub fn getOutput(self: *const @This()) std.Build.LazyPath {
    return .{ .generated = .{ .file = &self.output } };
}

pub fn make(step: *std.Build.Step, _: std.Build.Step.MakeOptions) !void {
    const self: *@This() = @fieldParentPtr("step", step);
    const b = step.owner;

    // Check the cache to see if we have any hits on what we're doing right now.
    var man = b.graph.cache.obtain();
    defer man.deinit();

    // Check all the possible variable data.
    man.hash.addBytes(self.basename);
    man.hash.add(self.disk.sectors);
    man.hash.add(self.disk.sector_size);
    for (self.table.inner.items) |item| {
        man.hash.addBytes(std.mem.sliceAsBytes(item.name));
        man.hash.add(item.start);
        man.hash.add(item.end);
        man.hash.add(item.attr);
    }
    man.hash.add(self.table.inner.items.len);
    const digest = man.final();
    const cache_path = "o" ++ std.fs.path.sep_str ++ digest;
    const full_path = try b.cache_root.join(b.allocator, &.{ cache_path, self.basename });

    errdefer b.allocator.free(full_path);

    // We got a hit, don't do anything.
    if (try step.cacheHit(&man)) {
        self.output.path = full_path;
        return;
    }
    if (self.table.inner.items.len == 0)
        return step.fail("Nothing left to do, the table length is 0", .{});

    // Create an empty file and truncate it to the requested size.
    const file = try std.fs.createFileAbsolute(full_path, .{ .truncate = true });
    defer file.close();

    // Truncate the file to the desired + extra size.
    try file.seekTo(self.disk.sectors * self.disk.sector_size - 1);
    try file.writeAll("\x00");

    // Commit changes to the disk. There are no preparations left to be done.
    // The raw GPT entries will be returned. Should we give them back in the 
    // step output or nah and just free them like it is now?
    const raw_ents = try self.table.commit(b.allocator, self.disk, file);
    b.allocator.free(raw_ents);

    // Set the path to the resulting disk image.
    self.output.path = full_path;

    // Done. Write the manifest so that we can avoid repeating the same work.
    try man.writeManifest();
}
