const std = @import("std");
const fs = @import("fs");
const native_endian = @import("builtin").target.cpu.arch.endian();
const testing = std.testing;

const GUID = struct {
    data1: u32,
    data2: u32,
    data3: u32,
    data4: [8]u32,
};

const WAVEFORMATEXT = struct {
    format_tag: u32,
    num_channels: u32,
    samples_per_sec: u64,
    avg_bytes_per_sec: u64,
    block_align: u32,
    bits_per_sample: u32,
    cb_size: u32,
};

const WAVEFORMATEXTENSIBLE = struct {
    format: WAVEFORMATEXT,
    samples: Samples,
    channel_mask: u64,
    sub_format: GUID,
};

const WAVEFORMAT = struct {
    format_tag: u32,
    num_channels: u32,
    samples_per_sec: u64,
    avg_bytes_per_sec: u64,
    block_align: u32,
    bits_per_sample: u32,
};

const ChPeak = struct {
    val: f32,
    pos: c_ulong,
};

const KSDATAFORMAT_SUBTYPE_PCM = GUID{
    .data1 = 0x00000001,
    .data2 = 0x0000,
    .data3 = 0x0010,
    .data4 = [8]u32{ 0x80, 0x00, 0x00, 0xaa, 0x00, 0x38, 0x9b, 0x71 },
};

const FilePos = c_ulonglong;
const Time = c_ulong;

const LastOp = enum { read, write };
const PSFFormat = enum { unknown, wav, wavex };
const PSFSType = enum { samp_unknown, samp_8, samp_16, samp_24, samp_32, samp_ieee_float };
const PSFChannelFormat = enum { std_wave };
const Samples = union {
    valid_bits_per_sample: u32,
    samples_per_block: u32,
    reserved: u32,
};

const SizeError = error{TypeNotFound};

const PSFMaxFiles = 64;

const PSFFile = struct {
    file: *fs.File,
    file_name: []u32,
    curr_frame_pos: u64,
    num_frames: u64,
    is_little_endian: u8,
    is_read: bool,
    clip_floats: bool,
    rescale: bool,
    rescale_fact: f32,
    riff_format: PSFFormat,
    samp_type: PSFSType,
    data_offset: FilePos,
    fmt_offset: FilePos,
    fmt: WAVEFORMATEXTENSIBLE,
    channel_format: PSFChannelFormat,
    peak: *ChPeak,
    peak_time: Time,
    last_write_pos: FilePos,
    last_op: LastOp,
    dither_type: u8,
};

const PSFFiles = *[PSFMaxFiles]PSFFile;

pub fn psfInit() void {
    for (0..PSFMaxFiles) |i| {
        PSFFiles[i] = null;
    }
}

pub fn psfReleaseFile(ps_file: *PSFFile) !void {
    if (ps_file.file != null) {
        std.os.close(ps_file.file_name);
    }

    if (ps_file.file_name.len > 0) {
        ps_file.file_name = "";
    }

    if (ps_file.peak != null) {
        ps_file.peak = null;
    }

    return;
}

pub fn psfFinish() !void {
    for (0..PSFMaxFiles) |i| {
        if (PSFFiles[i] != null) {
            psfReleaseFile(PSFFiles(i));
        }

        PSFFiles[i] = null;
    }

    return;
}

// UTILITIES

pub fn byteOrder() u8 {
    if (native_endian == .little) {
        return 1;
    }

    return 0;
}

pub fn bitSize(s_type: PSFSType) !u4 {
    switch (s_type) {
        PSFSType.samp_24 => return 24,
        PSFSType.samp_16 => return 16,
        PSFSType.samp_32, PSFSType.samp_ieee_float => return 32,
        else => return SizeError.TypeNotFound,
    }
}

pub fn wordSize(s_type: PSFSType) !u4 {
    switch (s_type) {
        PSFSType.samp_24 => return 2,
        PSFSType.samp_16 => return 3,
        PSFSType.samp_32, PSFSType.samp_ieee_float => return 4,
        else => return SizeError.TypeNotFound,
    }
}

pub fn compareGUIDs(right: GUID, left: GUID) bool {
    if (right.data1 != left.data1) {
        return false;
    } else if (right.data2 != left.data2) {
        return false;
    } else if (right.data3 != left.data3) {
        return false;
    }

    return std.mem.eql(u32, &right.data4, &left.data4);
}

pub fn checkGUID(sf_dat: *PSFFile) bool {
    if (sf_dat.riff_format != PSFFormat.wavex) {
        return false;
    }

    if (compareGUIDs(sf_dat.fmt.sub_format, KSDATAFORMAT_SUBTYPE_PCM)) {
        switch (sf_dat.fmt.format.bits_per_sample) {
            16 => sf_dat.samp_type = PSFSType.samp_16,
            24 => {
                if ((sf_dat.fmt.format.block_align / sf_dat.fmt.format.num_channels) != 3) {
                    sf_dat.samp_type = PSFSType.samp_unknown;
                    return false;
                }

                sf_dat.samp_type = PSFSType.samp_24;
            },
            32 => sf_dat.samp_type = PSFSType.samp_32,
            else => {
                sf_dat.samp_type = PSFSType.samp_unknown;
                return false;
            },
        }

        return true;
    }

    return false;
}

pub fn main() !void {
    std.debug.print("All your {s} are belong to us.\n", .{"sounds"});

    std.debug.print("endianness: {}\n", .{byteOrder()});
}

test "GUID comparison" {
    const first = GUID{
        .data1 = 1,
        .data2 = 2,
        .data3 = 3,
        .data4 = [8]u32{ 4, 6, 7, 8, 9, 10, 11, 12 },
    };

    const second = GUID{
        .data1 = 1,
        .data2 = 2,
        .data3 = 3,

        .data4 = [8]u32{ 4, 6, 7, 8, 9, 10, 11, 12 },
    };

    const differentArray = GUID{
        .data1 = 1,
        .data2 = 2,
        .data3 = 3,

        .data4 = [8]u32{ 6, 6, 6, 8, 9, 10, 11, 12 },
    };

    const differentNumField = GUID{
        .data1 = 2,
        .data2 = 2,
        .data3 = 3,

        .data4 = [8]u32{ 4, 6, 7, 8, 9, 10, 11, 12 },
    };

    try testing.expect(compareGUIDs(first, second) == true);
    try testing.expect(compareGUIDs(first, differentArray) == false);
    try testing.expect(compareGUIDs(first, differentNumField) == false);
}
