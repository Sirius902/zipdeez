const std = @import("std");
const Allocator = std.mem.Allocator;

allocator: Allocator,
headers: []LocalFileHeader,

const Self = @This();
const log = std.log.scoped(.zzip);

pub fn parse(allocator: Allocator, reader: anytype) (error{EndOfStream} || ParseError || Allocator.Error || @TypeOf(reader).Error)!Self {
    var headers = std.ArrayList(LocalFileHeader).init(allocator);
    errdefer {
        for (headers.items) |header| {
            header.deinit(allocator);
        }
        headers.deinit();
    }

    while (true) {
        var header = try LocalFileHeader.parse(allocator, reader);
        errdefer header.deinit(allocator);
        try headers.append(header);

        // Skip compressed data
        try reader.skipBytes(header.compressed_size, .{});
    }

    return .{ .allocator = allocator, .headers = headers };
}

pub fn deinit(self: Self) void {
    for (self.headers) |header| {
        header.deinit(self.allocator);
    }
    self.allocator.free(self.headers);
}

pub const ParseError = error{
    BadMagic,
    UnsupportedZip,
    UnexpectedEndOfStream,
};

const FileHeader = union(enum) {
    local: LocalFileHeader,
    central_directory: CentralDirectoryFileHeader,
};

const LocalFileHeader = struct {
    magic: u32,
    version_needed: u16,
    general_purpose_bit_flag: u16,
    compression_method: u16,
    file_modification_time: u16,
    file_modification_date: u16,
    uncompressed_crc: u32,
    // 0xffffffff for ZIP64
    compressed_size: u32,
    // 0xffffffff for ZIP64
    uncompressed_size: u32,
    file_name: []const u8,
    extra_field: []const u8,

    const local_file_magic = 0x04034b50;

    const Raw = struct {
        magic: u32,
        version_needed: u16,
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

    pub fn parse(allocator: Allocator, reader: anytype) (error{EndOfStream} || ParseError || Allocator.Error || @TypeOf(reader).Error)!LocalFileHeader {
        const raw = try readFieldsLittle(Raw, reader);
        if (raw.magic != local_file_magic) {
            // TODO: Change to stream for offset in errors?
            log.debug("Bad magic: 0x{x:0>8}", .{raw.magic});
            return error.BadMagic;
        }

        // TODO: ZIP64
        if ((raw.general_purpose_bit_flag & 0x08) != 0) {
            log.debug("Data descriptor flag not supported", .{});
            return error.UnsupportedZip;
        }

        const file_name = try readFixedString(allocator, raw.file_name_len, reader);
        errdefer allocator.free(file_name);

        const extra_field = try readFixedString(allocator, raw.extra_field_len, reader);
        errdefer allocator.free(extra_field);

        return .{
            .magic = raw.magic,
            .version_needed = raw.version_needed,
            .general_purpose_bit_flag = raw.general_purpose_bit_flag,
            .compression_method = raw.compression_method,
            .file_modification_time = raw.file_modification_time,
            .file_modification_date = raw.file_modification_date,
            .uncompressed_crc = raw.uncompressed_crc,
            .compressed_size = raw.compressed_size,
            .uncompressed_size = raw.uncompressed_size,
            .file_name = file_name,
            .extra_field = extra_field,
        };
    }

    pub fn deinit(self: LocalFileHeader, allocator: Allocator) void {
        allocator.free(self.file_name);
        allocator.free(self.extra_field);
    }
};

// TODO: Implement
const CentralDirectoryFileHeader = struct {};

fn readFieldsLittle(comptime T: type, reader: anytype) (error{EndOfStream} || @TypeOf(reader).Error)!T {
    var t: T = undefined;

    inline for (std.meta.fields(T)) |field| {
        if (@typeInfo(field.type) == .Struct) {
            @field(t, field.name) = try readFieldsLittle(field.type, reader);
        } else {
            @field(t, field.name) = try reader.readIntLittle(field.type);
        }
    }

    return t;
}

fn readFixedString(allocator: Allocator, len: usize, reader: anytype) (error{EndOfStream} || ParseError || Allocator.Error || @TypeOf(reader).Error)![]u8 {
    const str = try allocator.alloc(u8, len);
    errdefer allocator.free(str);

    const read_len = try reader.readAll(str);
    if (read_len != str.len) {
        return error.UnexpectedEndOfStream;
    }

    return str;
}
