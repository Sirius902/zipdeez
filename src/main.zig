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

    var zip = try Zip.open(allocator, std.io.StreamSource{
        .file = zip_file,
    });
    defer zip.deinit();

    var iterator = try zip.iterator();
    while (try iterator.next()) |entry| {
        defer entry.close();
        std.log.info("entry = {}", .{entry});
    }
}
