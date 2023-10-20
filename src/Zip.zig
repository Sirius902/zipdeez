const std = @import("std");
const builtin = @import("builtin");
const deflate = std.compress.deflate;
const Allocator = std.mem.Allocator;
const StreamSource = std.io.StreamSource;

allocator: Allocator,
stream: StreamSource,
deflate_decompressor: deflate.Decompressor(StreamSource.Reader),
end_record_pos: u64,

pub const Error = error{
    BadMagic,
    UnsupportedZip,
    UnsupportedCompression,
    CorruptedZip,
    Unseekable,
    // TODO: Maybe replace these with UnexpectedEndOfStream.
    EndOfStream,
} || Allocator.Error;

const Self = @This();
const log = std.log.scoped(.zipdeez);
const native_endian = builtin.cpu.arch.endian();

pub fn open(allocator: Allocator, stream: StreamSource) (Error || StreamSource.ReadError)!Self {
    var s = stream;
    return .{
        .allocator = allocator,
        .stream = stream,
        .deflate_decompressor = try deflate.decompressor(allocator, s.reader(), null),
        .end_record_pos = try locateEndRecord(&s),
    };
}

pub fn create(allocator: Allocator, stream: StreamSource) (Error || StreamSource.ReadError)!Self {
    _ = allocator;
    _ = stream;
    @panic("unimplemented");
}

/// Release all allocated memory.
pub fn deinit(self: *Self) void {
    self.deflate_decompressor.deinit();
}

pub fn iterator(self: *Self) (Error || StreamSource.ReadError)!Iterator {
    return try Iterator.init(self);
}

fn resetDeflateDecompressor(self: *Self) Error!void {
    // TODO: It seems like the reset method does not reset all state.
    self.deflate_decompressor.deinit();
    self.deflate_decompressor = try deflate.decompressor(self.allocator, self.stream.reader(), null);
}

// TODO: Maybe this should be on `Entry`.
fn seekToEntryData(self: *Self, local_file_pos: u64) (Error || StreamSource.ReadError)!void {
    try self.stream.seekTo(local_file_pos);

    const header = try readFieldsLittle(LocalFileHeader, self.stream.reader());
    if (header.magic != .local_file) {
        log.err("Expected local file magic, got 0x{x:0>8}: pos = {}", .{
            @intFromEnum(header.magic),
            try self.stream.getPos(),
        });
        return error.BadMagic;
    }

    try self.stream.seekBy(header.info.file_name_len +
        header.info.extra_field_len);
}

// TODO: Ensure end record data is supported before using it.
fn locateEndRecord(stream: *StreamSource) (Error || StreamSource.ReadError)!u64 {
    const end_record_min_size = streamedSize(EndRecordHeader);
    const end_pos = try stream.getEndPos();
    if (end_pos < end_record_min_size) {
        log.err("Archive too small", .{});
        return error.CorruptedZip;
    }

    var reader = stream.reader();
    var pos = end_pos - end_record_min_size;
    while (true) {
        try stream.seekTo(pos);

        if (try reader.readIntLittle(u32) == @intFromEnum(Magic.end_record)) {
            try stream.seekTo(pos);
            // TODO: Remove
            log.debug("Found end record = {}", .{try readFieldsLittle(EndRecordHeader, stream.reader())});
            return pos;
        }

        if (pos == 0) {
            break;
        } else {
            pos -= 1;
        }
    }

    log.err("Archive missing end of central directory record", .{});
    return error.CorruptedZip;
}

fn endRecordHeader(self: *Self) (Error || StreamSource.ReadError)!EndRecordHeader {
    try self.stream.seekTo(self.end_record_pos);

    const header = try readFieldsLittle(EndRecordHeader, self.stream.reader());
    if (header.magic != .end_record) {
        log.err("Expected end of central directory magic, got 0x{x:0>8}: pos = {}", .{
            @intFromEnum(header.magic),
            try self.stream.getPos(),
        });
        return error.BadMagic;
    }

    return header;
}

fn streamedSize(comptime T: type) comptime_int {
    if (@typeInfo(T) != .Struct or @bitSizeOf(T) % 8 != 0) {
        @compileError("invalid type");
    }

    inline for (std.meta.fields(T)) |field| {
        if (field.is_comptime) {
            @compileError("comptime field not allowed");
        }

        switch (@typeInfo(field.type)) {
            .Enum => |enum_info| {
                if (enum_info.is_exhaustive) {
                    @compileError("enum field must be non-exhaustive");
                }
            },
            .Union, .ErrorSet => @compileError("invalid field type"),
            else => {},
        }
    }

    return @bitSizeOf(T) / 8;
}

fn readFieldsLittle(comptime T: type, reader: anytype) (@TypeOf(reader).Error || error{EndOfStream})!T {
    var t: T = undefined;
    try reader.readNoEof(std.mem.asBytes(&t)[0..streamedSize(T)]);

    switch (native_endian) {
        .Little => {},
        .Big => std.mem.byteSwapAllFields(T, &t),
    }

    return t;
}

fn readFixedString(allocator: Allocator, len: usize, reader: anytype) (@TypeOf(reader).Error || Allocator.Error || error{EndOfStream})![]u8 {
    const str = try allocator.alloc(u8, len);
    errdefer allocator.free(str);
    try reader.readNoEof(str);
    return str;
}

// TODO: Multiple iterators at once will not work due to them sharing the same stream.
/// Iterators are invalidated when the underlying `Zip` is modified.
pub const Iterator = struct {
    zip: *Self,
    end_record_header: EndRecordHeader,
    entry_index: usize,
    entry_pos: u64,

    fn init(zip: *Self) (Error || StreamSource.ReadError)!Iterator {
        const header = try zip.endRecordHeader();
        return .{
            .zip = zip,
            .end_record_header = header,
            .entry_index = 0,
            .entry_pos = header.central_directory_start_pos,
        };
    }

    pub fn next(self: *Iterator) (Error || StreamSource.ReadError)!?Entry {
        if (self.entry_index >= self.end_record_header.disk_central_directory_count) {
            return null;
        }

        const zip = self.zip;
        try zip.stream.seekTo(self.entry_pos);

        const header = try readFieldsLittle(CentralFileHeader, zip.stream.reader());
        if (header.magic != .central_file) {
            log.err("Expected central directory file header magic, got 0x{x:0>8}: pos = {}", .{
                @intFromEnum(header.magic),
                try zip.stream.getPos(),
            });
            return error.BadMagic;
        }

        const file_name = try readFixedString(
            zip.allocator,
            header.local_file.file_name_len,
            zip.stream.reader(),
        );
        errdefer zip.allocator.free(file_name);

        const extra_field = try readFixedString(
            zip.allocator,
            header.local_file.extra_field_len,
            zip.stream.reader(),
        );
        errdefer zip.allocator.free(extra_field);

        const file_comment = try readFixedString(
            zip.allocator,
            header.file_comment_len,
            zip.stream.reader(),
        );
        errdefer zip.allocator.free(file_comment);

        self.entry_index += 1;
        self.entry_pos = try zip.stream.getPos();
        try zip.seekToEntryData(header.local_file_pos);

        // Reset decompressor so file data can be read from the entry.
        if (header.local_file.compression_method == .deflate) {
            try zip.resetDeflateDecompressor();
        }

        return .{
            .zip = zip,
            .hasher = std.hash.Crc32.init(),
            .info = .{
                .version_made_by = header.version_made_by,
                .min_version_needed = header.local_file.min_version_needed,
                .flags = header.local_file.flags,
                .compression_method = header.local_file.compression_method,
                .file_modification_time = header.local_file.file_modification_time,
                .file_modification_date = header.local_file.file_modification_date,
                .uncompressed_crc = header.local_file.uncompressed_crc,
                .compressed_size = header.local_file.compressed_size,
                .uncompressed_size = header.local_file.uncompressed_size,
                .file_name = file_name,
                .extra_field = extra_field,
                .file_comment = file_comment,
                .file_disk_num = header.file_disk_num,
                .internal_file_attributes = header.internal_file_attributes,
                .external_file_attributes = header.external_file_attributes,
                .local_file_pos = header.local_file_pos,
            },
        };
    }
};

pub const EntryInfo = struct {
    version_made_by: u16,
    min_version_needed: u16,
    flags: FileFlags,
    compression_method: CompressionMethod,
    file_modification_time: u16,
    file_modification_date: u16,
    uncompressed_crc: u32,
    compressed_size: u32,
    uncompressed_size: u32,
    file_name: []const u8,
    extra_field: []const u8,
    file_comment: []const u8,
    file_disk_num: u16,
    internal_file_attributes: u16,
    external_file_attributes: u32,
    local_file_pos: u32,
};

// TODO: Maybe make `Entry` itself not a reader. Case in point you can't directly call `Entry.reader` while iterating.
/// Entries must not be read after advancing past them using `Iterator.next`.
pub const Entry = struct {
    zip: *Self,
    /// Information about the file referenced by this `Entry`.
    info: EntryInfo,
    hasher: std.hash.Crc32,
    // TODO: Make separate reader for raw mode. It's a bit cluttered.
    /// Changes if raw mode is enabled for reading. No decompression will occur
    /// regardless of the compression mode if this is enabled. Compressed data
    /// read with raw mode will not have their CRC computed.
    ///
    /// Raw mode must not be changed while reading from the stream.
    raw_mode: bool = false,
    bytes_read: usize = 0,

    // TODO: Do something so that this can also be called Error. Also returning the entire set of `Decompressor` errors
    // isn't ideal.
    pub const ReadError = Error || StreamSource.ReadError || deflate.Decompressor(StreamSource.Reader).Error;
    pub const Reader = std.io.Reader(*Entry, ReadError, read);

    pub fn close(self: Entry) void {
        self.zip.allocator.free(self.info.file_name);
        self.zip.allocator.free(self.info.extra_field);
        self.zip.allocator.free(self.info.file_comment);
    }

    pub fn reader(self: *Entry) Reader {
        return .{ .context = self };
    }

    fn read(self: *Entry, buffer: []u8) ReadError!usize {
        log.debug("Reading entry at pos {}", .{try self.zip.stream.getPos()});

        const compression = if (self.raw_mode) .store else self.info.compression_method;
        const do_crc = !self.raw_mode or self.info.compression_method == .store;

        const bytes_left = (if (self.raw_mode) self.info.compressed_size else self.info.uncompressed_size) - self.bytes_read;
        if (bytes_left == 0) {
            if (compression == .deflate) {
                if (self.zip.deflate_decompressor.close()) |err| {
                    log.err("Deflate error: entry = \"{s}\"", .{self.info.file_name});
                    return err;
                }
            }

            const computed_crc = self.hasher.final();
            if (do_crc and computed_crc != self.info.uncompressed_crc) {
                log.err("CRC mismatch: expected 0x{x:0>8}, got 0x{x:0>8}: entry = \"{s}\"", .{
                    self.info.uncompressed_crc,
                    computed_crc,
                    self.info.file_name,
                });
                return error.CorruptedZip;
            }

            return 0;
        }

        const max_read = @min(buffer.len, bytes_left);
        const read_len = switch (compression) {
            .store => try self.zip.stream.read(buffer[0..max_read]),
            .deflate => try self.zip.deflate_decompressor.read(buffer[0..max_read]),
            else => {
                log.err("Unsupported compression method = {}: entry = \"{s}\"", .{ compression, self.info.file_name });
                return error.UnsupportedCompression;
            },
        };
        defer self.bytes_read += read_len;

        log.debug("Read {} bytes with {} left", .{ read_len, bytes_left });

        self.hasher.update(buffer[0..read_len]);
        return read_len;
    }
};

pub const CompressionMethod = enum(u16) {
    store = 0,
    deflate = 8,
    _,
};

pub const FileFlags = packed struct {
    flags0: u3,
    data_descriptor: bool,
    flags4: u12,
};

const Magic = enum(u32) {
    local_file = 0x04034b50,
    data_descriptor = 0x08074b50,
    central_file = 0x02014b50,
    end_record = 0x06054b50,
    _,
};

const LocalFileInfo = packed struct {
    min_version_needed: u16,
    flags: FileFlags,
    compression_method: CompressionMethod,
    file_modification_time: u16,
    file_modification_date: u16,
    uncompressed_crc: u32,
    compressed_size: u32,
    uncompressed_size: u32,
    file_name_len: u16,
    extra_field_len: u16,
};

const LocalFileHeader = packed struct {
    magic: Magic = .local_file,
    info: LocalFileInfo,
};

// TODO: Magic is optional and sizes are u64 for ZIP64.
const DataDescriptor = packed struct {
    magic: Magic = .data_descriptor,
    uncompressed_crc: u32,
    compressed_size: u32,
    uncompressed_size: u32,
};

const CentralFileHeader = packed struct {
    magic: Magic = .central_file,
    version_made_by: u16,
    local_file: LocalFileInfo,
    file_comment_len: u16,
    file_disk_num: u16,
    internal_file_attributes: u16,
    external_file_attributes: u32,
    local_file_pos: u32,
};

// TODO: Add a way to expose this data like `Entry`.
const EndRecordHeader = packed struct {
    magic: Magic = .end_record,
    // ~0 for ZIP64
    disk_number: u16,
    central_directory_disk_number: u16,
    disk_central_directory_count: u16,
    total_central_directory_count: u16,
    central_directory_size: u32,
    central_directory_start_pos: u32,
    comment_len: u16,
};
