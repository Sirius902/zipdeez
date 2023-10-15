const std = @import("std");
const Allocator = std.mem.Allocator;
const Decompressor = std.compress.deflate.Decompressor;

const log = std.log.scoped(.zzip);

const header_magic = struct {
    pub const local_file = 0x04034b50;
    pub const data_descriptor = 0x08074b50;
    pub const central_directory_file = 0x02014b50;
    pub const central_directory_end = 0x06054b50;
};

pub fn Iterator(comptime Reader: type) type {
    return struct {
        allocator: Allocator,
        reader: Reader,
        entry: ?Entry = null,
        skip_entry_data: bool = true,

        const Self = @This();

        pub const Error = error{
            BadMagic,
            UnsupportedZip,
            CorruptedZip,
            NoEntry,
            EntryAlreadyRead,
            UnexpectedEndOfStream,
        } || Reader.Error || Allocator.Error || Decompressor(Reader).Error;

        /// Returns the next zip file entry.
        /// Caller must call `Entry.close` to free allocated memory.
        pub fn next(self: *Self) Error!?*const Entry {
            self.readNextEntry() catch |err| return switch (err) {
                error.EndOfStream => error.UnexpectedEndOfStream,
                else => |e| e,
            };

            if (self.entry) |*e| {
                // TODO: Don't return a pointer here
                return e;
            } else {
                return null;
            }
        }

        // TODO: Use writer instead
        pub fn readEntryDataAlloc(self: *Self, allocator: Allocator) Error![]u8 {
            return self.readEntryDataAllocRaw(allocator) catch |err| switch (err) {
                error.EndOfStream => error.UnexpectedEndOfStream,
                else => |e| e,
            };
        }

        pub fn readEntryDataAllocRaw(self: *Self, allocator: Allocator) (Error || error{EndOfStream})![]u8 {
            if (!self.skip_entry_data) {
                return error.EntryAlreadyRead;
            }
            self.skip_entry_data = false;

            if (self.entry) |entry| {
                var data = try allocator.alloc(u8, entry.uncompressed_size);
                errdefer allocator.free(data);

                switch (entry.compression_method) {
                    .store => try self.reader.readNoEof(data),
                    .deflate => {
                        var decompressor = try std.compress.deflate.decompressor(allocator, self.reader, null);
                        defer decompressor.deinit();
                        const reader = decompressor.reader();

                        try reader.readNoEof(data);
                        if (decompressor.close()) |err| {
                            return err;
                        }
                    },
                }

                // TODO: Hash as data is being read
                if (std.hash.Crc32.hash(data) != entry.uncompressed_crc) {
                    return error.CorruptedZip;
                }

                return data;
            } else {
                return error.NoEntry;
            }
        }

        fn readNextEntry(self: *Self) (Error || error{EndOfStream})!void {
            if (self.entry) |*e| {
                defer self.entry = null;

                if (self.skip_entry_data) {
                    try self.reader.skipBytes(e.compressed_size, .{});
                }
            }
            self.skip_entry_data = true;

            while (true) {
                const magic = try self.reader.readIntLittle(u32);
                switch (magic) {
                    header_magic.local_file => {
                        log.debug("Found local file header", .{});

                        const header = try self.readFieldsLittle(LocalFileHeader);
                        const file_name = try self.readFixedString(header.file_name_len);
                        errdefer self.allocator.free(file_name);

                        const extra_field = try self.readFixedString(header.extra_field_len);
                        errdefer self.allocator.free(extra_field);

                        const compression_method = blk: {
                            inline for (comptime std.enums.values(CompressionMethod)) |method| {
                                if (@intFromEnum(method) == header.compression_method) {
                                    break :blk method;
                                }
                            } else {
                                log.err("Unsupported compression method: {}", .{header.compression_method});
                                return error.UnsupportedZip;
                            }
                        };

                        log.debug("Parsed local file header: name = \"{s}\", extra_field_len = {}, compression_method = {}", .{
                            file_name,
                            extra_field.len,
                            compression_method,
                        });

                        if ((header.general_purpose_bit_flag & 8) != 0) {
                            log.err("Data descriptors are unsupported", .{});
                            return error.UnsupportedZip;
                        }

                        if (header.compressed_size == ~@as(u32, 0) or header.uncompressed_size == ~@as(u32, 0)) {
                            log.err("ZIP64 is unsupported", .{});
                            return error.UnsupportedZip;
                        }

                        self.entry = .{
                            .minimum_version_needed = header.minimum_version_needed,
                            .general_purpose_bit_flag = header.general_purpose_bit_flag,
                            .compression_method = compression_method,
                            .file_modification_time = header.file_modification_time,
                            .file_modification_date = header.file_modification_date,
                            .uncompressed_crc = header.uncompressed_crc,
                            .compressed_size = header.compressed_size,
                            .uncompressed_size = header.uncompressed_size,
                            .file_name = file_name,
                            .extra_field = extra_field,
                        };
                        return;
                    },
                    // TODO: Unsure of how this works, find out and implement
                    // Be weary that what is used as the magic value here could've actually been the CRC.
                    header_magic.data_descriptor => {
                        log.debug("Found data descriptor", .{});
                        return error.UnsupportedZip;
                    },
                    header_magic.central_directory_file => {
                        log.debug("Found central directory file header", .{});
                        // TODO: Properly parse central directory file
                        log.warn("Skipping central directory file", .{});

                        try self.reader.skipBytes(24, .{});
                        const file_name_len = try self.reader.readIntLittle(u16);
                        const extra_field_len = try self.reader.readIntLittle(u16);
                        const file_comment_len = try self.reader.readIntLittle(u16);
                        try self.reader.skipBytes(12, .{});
                        try self.reader.skipBytes(file_name_len, .{});
                        try self.reader.skipBytes(extra_field_len, .{});
                        try self.reader.skipBytes(file_comment_len, .{});
                    },
                    // TODO: Return central directory end data to user
                    header_magic.central_directory_end => {
                        log.debug("Found end of central directory record", .{});
                        try self.reader.skipBytes(16, .{});
                        const comment_len = try self.reader.readIntLittle(u16);
                        try self.reader.skipBytes(comment_len, .{});
                        return;
                    },
                    else => {
                        // TODO: Change to stream for offset in errors?
                        log.err("Bad magic: 0x{x:0>8}", .{magic});
                        return error.BadMagic;
                    },
                }
            }
        }

        fn readFieldsLittle(self: Self, comptime T: type) (Error || error{EndOfStream})!T {
            var t: T = undefined;

            inline for (std.meta.fields(T)) |field| {
                if (@typeInfo(field.type) == .Struct) {
                    @field(t, field.name) = try readFieldsLittle(field.type, self.reader);
                } else {
                    @field(t, field.name) = try self.reader.readIntLittle(field.type);
                }
            }

            return t;
        }

        fn readFixedString(self: Self, len: usize) (Error || error{EndOfStream})![]u8 {
            const str = try self.allocator.alloc(u8, len);
            errdefer self.allocator.free(str);

            const read_len = try self.reader.readAll(str);
            if (read_len != str.len) {
                return error.UnexpectedEndOfStream;
            }

            return str;
        }
    };
}

pub fn iterator(allocator: Allocator, reader: anytype) Iterator(@TypeOf(reader)) {
    return .{ .allocator = allocator, .reader = reader };
}

pub const CompressionMethod = enum(u16) {
    store = 0,
    deflate = 8,
};

// TODO: ZIP64
pub const Entry = struct {
    minimum_version_needed: u16,
    general_purpose_bit_flag: u16,
    compression_method: CompressionMethod,
    file_modification_time: u16,
    file_modification_date: u16,
    uncompressed_crc: u32,
    compressed_size: u32,
    uncompressed_size: u32,
    file_name: []const u8,
    extra_field: []const u8,

    // TODO: I don't like this allocator business
    pub fn close(self: Entry, allocator: Allocator) void {
        allocator.free(self.file_name);
        allocator.free(self.extra_field);
    }
};

const LocalFileHeader = struct {
    minimum_version_needed: u16,
    general_purpose_bit_flag: u16,
    compression_method: u16,
    file_modification_time: u16,
    file_modification_date: u16,
    uncompressed_crc: u32,
    // 0xffffffff for ZIP64
    compressed_size: u32,
    // 0xffffffff for ZIP64
    uncompressed_size: u32,
    file_name_len: u16,
    extra_field_len: u16,
};
