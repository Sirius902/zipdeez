const std = @import("std");
const fs = std.fs;
const Allocator = std.mem.Allocator;
const Zip = @import("Zip.zig");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const zip_file = try fs.cwd().openFile("./zig-cache/bingus/Fanfare - Body Found.ootrs", .{});
    defer zip_file.close();

    var zip = try Zip.open(allocator, std.io.StreamSource{ .file = zip_file });
    defer zip.deinit();

    var iterator = try zip.iterator();
    while (try iterator.next()) |entry| {
        defer entry.close();

        std.log.debug("Getting data for \"{s}\" with method {} | compressed = {}, uncompressed = {}", .{
            entry.info.file_name,
            entry.info.compression_method,
            entry.info.compressed_size,
            entry.info.uncompressed_size,
        });

        const buf = try allocator.alloc(u8, 8192);
        defer allocator.free(buf);

        var total_read_len: usize = 0;
        var en = entry;
        while (true) {
            const read_len = try en.reader().readAll(buf);
            total_read_len += read_len;
            if (read_len < buf.len) break;
        }

        std.log.debug("Actual size = {}", .{total_read_len});
    }
}
