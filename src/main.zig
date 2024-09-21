const std = @import("std");
const fs = std.fs;
const native_endian = @import("builtin").target.cpu.arch.endian();
const testing = std.testing;
const arenaAllocator = std.heap.ArenaAllocator;
const pageAllocator = std.heap.ArenaAllocator;

const GUID = struct {
    data1: c_int,
    data2: c_short,
    data3: c_short,
    data4: [8]u32,
};

const WAVEFORMATEXT = struct {
    format_tag: c_short,
    num_channels: c_int,
    samples_per_sec: c_int,
    avg_bytes_per_sec: c_int,
    block_align: c_int,
    bits_per_sample: c_int,
    cb_size: c_short,
};

const WAVEFORMATEXTENSIBLE = struct {
    format: WAVEFORMATEXT,
    samples: Samples,
    channel_mask: c_int,
    sub_format: GUID,
};

const WAVEFORMAT = struct {
    format_tag: c_short,
    num_channels: c_short,
    samples_per_sec: c_int,
    avg_bytes_per_sec: c_int,
    block_align: c_short,
    bits_per_sample: c_short,
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

const LastOp = enum(u8) { read, write };
const PSFFormat = enum(u8) { unknown, wav, wavex };
const PSFSType = enum(u8) { samp_unknown, samp_8, samp_16, samp_24, samp_32, samp_ieee_float };
const PSFChannelFormat = enum(u8) { std_wave, mc_std };
const Samples = union {
    valid_bits_per_sample: c_ushort,
    samples_per_block: c_ushort,
    reserved: c_ushort,
};

const SizeError = error{TypeNotFound};
const NewFileError = error{
    InvalidFormat,
    InvalidChannels,
    InvalidChannelFormat,
    InvalidRate,
    InvalidSampleType,
};

const PSFMaxFiles = 64;
const WAVE_FORMAT_PCM = 0x0001;

const PSFFile = struct {
    file: ?*fs.File,
    file_name: []u32,
    curr_frame_pos: c_long,
    num_frames: c_long,
    is_little_endian: c_int,
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
    peak: ?*ChPeak,
    peak_time: Time,
    last_write_pos: FilePos,
    last_op: LastOp,
    dither_type: c_int,
};

const PSFProps = struct {
    s_rate: c_int,
    chans: c_int,
    s_type: PSFSType,
    format: PSFFormat,
    channel_format: PSFChannelFormat,
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

pub fn bitSize(s_type: PSFSType) !c_int {
    switch (s_type) {
        PSFSType.samp_24 => return 24,
        PSFSType.samp_16 => return 16,
        PSFSType.samp_32, PSFSType.samp_ieee_float => return 32,
        else => return SizeError.TypeNotFound,
    }
}

pub fn wordSize(s_type: PSFSType) !c_int {
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

// NEW FILE

pub fn newFile(props: ?PSFProps, allocator: *std.mem.Allocator) !*PSFFile {
    if (props != null) {
        if (props.?.chans <= 0) {
            return NewFileError.InvalidChannels;
        }
        if (props.?.s_rate <= 0) {
            return NewFileError.InvalidRate;
        }
        if (@intFromEnum(props.?.s_type) < @intFromEnum(PSFSType.samp_16)) {
            return NewFileError.InvalidSampleType;
        }
        if (@intFromEnum(props.?.s_type) > @intFromEnum(PSFSType.samp_ieee_float)) {
            return NewFileError.InvalidSampleType;
        }
        if (@intFromEnum(props.?.format) <= @intFromEnum(PSFFormat.unknown)) {
            return NewFileError.InvalidFormat;
        }
        if (@intFromEnum(props.?.format) > @intFromEnum(PSFFormat.wavex)) {
            return NewFileError.InvalidFormat;
        }
        if (props.?.channel_format != PSFChannelFormat.std_wave) {
            return NewFileError.InvalidChannelFormat;
        }
    }

    const psfFile: *PSFFile = try allocator.create(PSFFile);

    psfFile.last_write_pos = 0;
    psfFile.file = null;
    psfFile.file_name = &[_]u32{};
    psfFile.num_frames = 0;
    psfFile.curr_frame_pos = 0;
    psfFile.is_read = true;

    if (props != null) {
        psfFile.riff_format = props.?.format;
    } else {
        psfFile.riff_format = PSFFormat.wav;
    }

    psfFile.clip_floats = true;
    psfFile.rescale = false;
    psfFile.rescale_fact = 1.0;
    psfFile.is_little_endian = byteOrder();

    if (props != null) {
        psfFile.samp_type = props.?.s_type;
    } else {
        psfFile.samp_type = PSFSType.samp_16;
    }

    psfFile.data_offset = 0;
    psfFile.peak_time = 0;
    psfFile.fmt_offset = 0;
    psfFile.fmt.format.format_tag = WAVE_FORMAT_PCM;

    if (props != null) {
        psfFile.fmt.format.num_channels = props.?.chans;
        psfFile.fmt.format.samples_per_sec = props.?.s_rate;

        const sampleTypeSize = try wordSize(props.?.s_type);
        psfFile.fmt.format.block_align = psfFile.fmt.format.num_channels * sampleTypeSize;
        psfFile.fmt.format.bits_per_sample = try bitSize(props.?.s_type);
    } else {
        psfFile.fmt.format.num_channels = 1;
        psfFile.fmt.format.samples_per_sec = 44100;
        psfFile.fmt.format.block_align = psfFile.fmt.format.num_channels * @sizeOf(c_short);
        psfFile.fmt.format.bits_per_sample = @sizeOf(c_short) * 8;
    }

    psfFile.peak = null;
    psfFile.peak_time = 0;
    psfFile.fmt.format.cb_size = 0;
    psfFile.fmt.channel_mask = 0;

    if (props != null) {
        if (props.?.format == PSFFormat.wavex) {
            psfFile.fmt.format.cb_size = 22;

            if (psfFile.channel_format == PSFChannelFormat.std_wave) {
                psfFile.channel_format = PSFChannelFormat.mc_std;
            }

            switch (psfFile.channel_format) {
                else => {
                    psfFile.fmt.channel_mask = 0;
                },
            }
        }
    }

    psfFile.dither_type = 0;

    return psfFile;
}

pub fn main() !void {
    std.debug.print("All your {s} are belong to us.\n", .{"sounds"});

    var arena = arenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();

    var allocator = arena.allocator();

    _ = try newFile(null, &allocator);

    return;
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
