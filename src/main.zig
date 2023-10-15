const std = @import("std");
const fs = std.fs;
const Allocator = std.mem.Allocator;
const zip = @import("zip.zig");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const zip_file = try fs.cwd().openFile("./zig-cache/bingus/Fanfare - Body Found.ootrs", .{});
    defer zip_file.close();

    var buffered_reader = std.io.bufferedReader(zip_file.reader());
    var iterator = zip.iterator(allocator, buffered_reader.reader());

    while (try iterator.next()) |entry| {
        defer entry.close(allocator);

        const data = try iterator.readEntryDataAlloc(allocator);
        defer allocator.free(data);

        std.log.info("expected uncompressed size = {}, actual size = {}", .{ entry.uncompressed_size, data.len });
    }
}
