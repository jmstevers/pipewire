// `pipewire/src/examples/audio-capture.c` translated to Zig.

const std = @import("std");
const example_options = @import("example_options");
const log = std.log;
const tau: f32 = std.math.tau;

// Configure logging
pub const std_options: std.Options = .{
    .logFn = logFn,
};

// Normal code wouldn't need this conditional, we're just demonstrating both the static library and
// the Zig module here. Prefer the Zig module when possible. We wrap the C module in a struct just
// to make it look like the Zig module so that the rest of the file can use it as is.
const pw = if (example_options.use_zig_module)
    @import("pipewire")
else
    struct {
        pub const c = @import("pipewire");
    };

const dbg_ctx = pw.Logger.dbgCtx(.info, pw.Logger.scope);

const global = struct {
    const volume = 0.1;

    var format: pw.c.spa_audio_info = undefined;

    var runtime_log_level: std.log.Level = .info;

    var loop: ?*pw.c.pw_main_loop = null;
    var stream: ?*pw.c.pw_stream = null;
};

pub fn main() !void {
    // If we're linking with the Zig module, set up logging.
    if (example_options.use_zig_module) pw.Logger.init();

    // Configure our runtime log level
    const log_level_env_var = "AUDIO_CAPTURE_LOG_LEVEL";
    if (std.posix.getenv(log_level_env_var)) |level_str| {
        const levels: std.StaticStringMap(std.log.Level) = .initComptime(.{
            .{ "debug", .debug },
            .{ "info", .info },
            .{ "warn", .warn },
            .{ "err", .err },
        });
        if (levels.get(level_str)) |level| {
            global.runtime_log_level = level;
        } else {
            log.err("{s}: unknown level \"{s}\"", .{ log_level_env_var, level_str });
        }
    }

    pw.c.pw_init(0, null);
    defer pw.c.pw_deinit();

    // make a main loop. If you already have another main loop, you can add
    // the fd of this pipewire mainloop to it.
    global.loop = pw.c.pw_main_loop_new(null).?;
    defer pw.c.pw_main_loop_destroy(global.loop);

    // Create a simple stream, the simple stream manages the core and remote
    // objects for you if you don't need to deal with them.
    //
    // If you plan to autoconnect your stream, you need to provide at least
    // media, category and role properties.
    //
    // Pass your events and a user_data pointer as the last arguments. This
    // will inform you about the stream state. The most important event
    // you need to listen to is the process event where you need to produce
    // the data.
    const props = pw.c.pw_properties_new(
        pw.c.PW_KEY_MEDIA_TYPE,
        "Audio",
        pw.c.PW_KEY_MEDIA_CATEGORY,
        "Capture",
        pw.c.PW_KEY_MEDIA_ROLE,
        "Music",
        @as(?*anyopaque, null),
    ).?;

    // Set stream target if given on command line
    var args: std.process.ArgIterator = .init();
    _ = args.skip();
    if (args.next()) |arg| check(pw.c.pw_properties_set(props, pw.c.PW_KEY_TARGET_OBJECT, arg));

    // uncomment if you want to capture from the sink monitor ports
    // check(pw.c.pw_properties_set(props, pw.c.PW_KEY_STREAM_CAPTURE_SINK, "true"));

    global.stream = pw.c.pw_stream_new_simple(
        pw.c.pw_main_loop_get_loop(global.loop),
        "audio-capture",
        props,
        &.{
            .version = pw.c.PW_VERSION_STREAM_EVENTS,
            .param_changed = &onStreamParamChanged,
            .process = &onProcess,
        },
        null,
    ).?;
    defer pw.c.pw_stream_destroy(global.stream);

    var buffer: [1024]u8 align(@alignOf(u32)) = undefined;
    var b = std.mem.zeroInit(pw.c.spa_pod_builder, .{
        .data = &buffer,
        .size = buffer.len,
    });

    // Make one parameter with the supported formats.
    // We leave the channels and rate empty to accept the native graph rate and channels.
    var params: [1]?*const pw.c.spa_pod = undefined;
    var f: pw.c.spa_pod_frame = undefined;
    check(pw.c.spa_pod_builder_push_object(
        &b,
        &f,
        pw.c.SPA_TYPE_OBJECT_Format,
        pw.c.SPA_PARAM_EnumFormat,
    ));

    check(pw.c.spa_pod_builder_prop(&b, pw.c.SPA_FORMAT_mediaType, 0));
    check(pw.c.spa_pod_builder_id(&b, pw.c.SPA_MEDIA_TYPE_audio));

    check(pw.c.spa_pod_builder_prop(&b, pw.c.SPA_FORMAT_mediaSubtype, 0));
    check(pw.c.spa_pod_builder_id(&b, pw.c.SPA_MEDIA_SUBTYPE_raw));

    check(pw.c.spa_pod_builder_prop(&b, pw.c.SPA_FORMAT_AUDIO_format, 0));
    check(pw.c.spa_pod_builder_id(&b, pw.c.SPA_AUDIO_FORMAT_F32));

    const format: *const pw.c.spa_pod = @ptrCast(@alignCast(pw.c.spa_pod_builder_pop(&b, &f)));
    if (example_options.use_zig_module) {
        check(pw.c.spa_debugc_format(dbg_ctx, 2, null, format));
    }
    params[0] = format;

    // Now connect this stream. We ask that our process function is
    // called in a realtime thread.
    check(pw.c.pw_stream_connect(
        global.stream,
        pw.c.PW_DIRECTION_INPUT,
        pw.c.PW_ID_ANY,
        pw.c.PW_STREAM_FLAG_AUTOCONNECT |
            pw.c.PW_STREAM_FLAG_MAP_BUFFERS |
            pw.c.PW_STREAM_FLAG_RT_PROCESS,
        &params,
        1,
    ));

    // and wait while we let things run
    check(pw.c.pw_main_loop_run(global.loop));
}

// Be notified when the stream param changes. We're only looking at the
// format changes.
fn onStreamParamChanged(
    userdata: ?*anyopaque,
    id: u32,
    param: [*c]const pw.c.spa_pod,
) callconv(.c) void {
    _ = userdata;

    // null means to clear the format
    if (param == null or id != pw.c.SPA_PARAM_Format) return;

    if (pw.c.spa_format_parse(
        param,
        &global.format.media_type,
        &global.format.media_subtype,
    ) < 0) return;

    // only accept raw audio
    if (global.format.media_type != pw.c.SPA_MEDIA_TYPE_audio or
        global.format.media_subtype != pw.c.SPA_MEDIA_SUBTYPE_raw) return;

    // call a helper function to parse the format for us.
    check(pw.c.spa_format_audio_raw_parse(param, &global.format.info.raw));

    log.info(
        "capturing rate:{d} channels:{d}",
        .{ global.format.info.raw.rate, global.format.info.raw.channels },
    );
}

// our data processing function is in general:
//
// const b: *pw.c.pw_buffer = pw.c.pw_stream_dequeue_buffer(stream);
// defer pw.c.pw_stream_queue_buffer(stream, b);
//
// .. consume stuff in the buffer ...
fn onProcess(userdata: ?*anyopaque) callconv(.c) void {
    _ = userdata;

    var maybe_buffer: ?*pw.c.pw_buffer = null;
    while (true) {
        const t = pw.c.pw_stream_dequeue_buffer(global.stream) orelse break;
        if (maybe_buffer) |b| check(pw.c.pw_stream_queue_buffer(global.stream, b));
        maybe_buffer = t;
    }
    const b = maybe_buffer orelse {
        log.warn("out of buffers", .{});
        return;
    };
    defer check(pw.c.pw_stream_queue_buffer(global.stream, b));

    const buf: *pw.c.spa_buffer = b.buffer;

    log.debug("new buffer {*}", .{buf});

    const ddata = buf.datas[0].data orelse return;
    const samples: [*]f32 = @ptrCast(@alignCast(ddata));

    const channels_count = global.format.info.raw.channels;
    const samples_count = buf.datas[0].chunk.*.size / @sizeOf(f32);

    log.info("captured {d} samples", .{samples_count / channels_count});

    var max: f32 = 0;
    var peak: u32 = 0;
    for (0..channels_count) |c| {
        var n: u32 = c;
        while (n < samples_count) : (n += channels_count) {
            max = @max(max, @abs(samples[n]));
        }
        peak = @min(0, @max(max * 30, 39));
    }
}

fn check(res: c_int) void {
    if (res != 0) {
        std.debug.panic("pipewire call failed: {s}", .{pw.c.spa_strerror(res)});
    }
}

pub fn logFn(
    comptime level: std.log.Level,
    comptime scope: @TypeOf(.enum_literal),
    comptime format: []const u8,
    args: anytype,
) void {
    if (@intFromEnum(level) > @intFromEnum(global.runtime_log_level)) return;
    std.log.defaultLog(level, scope, format, args);
}
