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

    var buffered_reader = std.io.bufferedReader(zip_file.reader());
    const zip = try Zip.parse(allocator, buffered_reader.reader());
    defer zip.deinit();

    std.log.info("{}", .{zip});
}
