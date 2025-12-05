impl: Impl,

pub const InitError = error{
    OutOfMemory,
    /// There is no advertised job server.
    NoServer,
    /// The job server is advertising a communication method which is not known.
    UnknownMethod,
    /// The job server is advertising a communication method which is known but unsupported.
    UnsupportedMethod,
    /// A job server advertisement exists, but is malformed.
    InvalidArgument,
    /// The job server has shut down or is otherwise not available to connect to.
    ServerFailed,
    /// This process does not have permission to access the job server.
    AccessDenied,
};
pub fn init(arena: Allocator, env: *const std.process.EnvMap) InitError!Client {
    const env_val = env.get("ROBUST_JOBSERVER") orelse return error.NoServer;
    const idx = std.mem.findScalar(u8, env_val, ':') orelse return error.InvalidArgument;
    const method = std.meta.stringToEnum(job.Method, env_val[0..idx]) orelse return error.UnknownMethod;
    switch (method) {
        inline else => |m| {
            const ImplTy = @FieldType(Impl, @tagName(m));
            if (ImplTy == noreturn) return error.UnsupportedMethod;
            return .{ .impl = @unionInit(
                Impl,
                @tagName(m),
                try .init(arena, env_val[idx + 1 ..]),
            ) };
        },
    }
}
pub fn deinit(c: *Client) void {
    switch (c.impl) {
        inline else => |*x| x.deinit(),
    }
    c.* = undefined;
}

pub const AcquireError = error{
    /// The job server has shut down or is otherwise not available to connect to.
    ServerFailed,
    /// This process does not have permission to access the job server.
    AccessDenied,
    /// Insufficient resources are available to acquire a token.
    SystemResources,
    Unexpected,
};
pub fn acquire(c: *const Client) AcquireError!Token {
    return switch (c.impl) {
        inline else => |*impl| impl.acquire(),
    };
}

const Impl = union(job.Method) {
    sysvsem: if (job.sysv_sem.supported) SysVSem else noreturn,
    win32pipe: if (builtin.target.os.tag == .windows) Win32Pipe else noreturn,
};

pub const Token = union(job.Method) {
    sysvsem: if (job.sysv_sem.supported) SysVSem else noreturn,
    win32pipe: if (builtin.target.os.tag == .windows) windows.HANDLE else noreturn,
    pub fn release(t: Token) void {
        switch (t) {
            .sysvsem => |sem| while (true) {
                return job.sysv_sem.modify(sem.set_id, 1) catch |err| switch (err) {
                    error.AccessDenied, error.InvalidSemaphore => {
                        // The semaphore broke somehow, but that's not our problem!
                        // (...at least, not until we next call `acquire`.)
                    },
                    error.SystemResources => unreachable, // the undo structure was already allocated in `acquire`
                    error.Interrupted => continue, // releasing can't block; just retry
                    error.Unexpected => {}, // already warned, nothing more we can do
                };
            },
            .win32pipe => |handle| _ = windows.ntdll.NtClose(handle),
        }
    }
};

const SysVSem = struct {
    set_id: i32,
    fn init(arena: Allocator, arg: []const u8) InitError!SysVSem {
        _ = arena;
        const set_id = std.fmt.parseInt(i32, arg, 10) catch return error.InvalidArgument;
        return .{ .set_id = set_id };
    }
    fn deinit(sem: SysVSem) void {
        _ = sem;
    }
    fn acquire(sem: SysVSem) AcquireError!Token {
        while (true) {
            break job.sysv_sem.modify(sem.set_id, -1) catch |err| switch (err) {
                error.InvalidSemaphore => return error.ServerFailed,
                error.Interrupted => continue, // TODO: support cancelation
                error.AccessDenied, error.SystemResources, error.Unexpected => |e| return e,
            };
        }
        return .{ .sysvsem = sem };
    }
};

const Win32Pipe = struct {
    pipe_device: windows.HANDLE,
    pipe_path: [:0]const u16,
    fn init(arena: Allocator, arg: []const u8) InitError!Win32Pipe {
        if (arg.len == 0) return error.InvalidArgument;
        if (std.mem.findAny(u8, arg, "\\/\x00") != null) return error.InvalidArgument;
        const pipe_path = std.unicode.wtf8ToWtf16LeAllocZ(
            arena,
            try std.fmt.allocPrint(arena, "\\??\\pipe\\{s}", .{arg}),
        ) catch |err| switch (err) {
            error.InvalidWtf8 => return error.InvalidArgument,
            error.OutOfMemory => |e| return e,
        };
        const pipe_device = windows.OpenFile(
            std.unicode.wtf8ToWtf16LeStringLiteral("\\??\\pipe\\"),
            .{
                .access_mask = .{
                    .SPECIFIC = .{ .FILE_PIPE = .{ .READ_ATTRIBUTES = true } },
                    .STANDARD = .{ .SYNCHRONIZE = true },
                },
                .share_access = .{ .READ = true, .WRITE = true },
                .creation = .OPEN,
            },
        ) catch |err| {
            // This fixed path should always be accessible on Windows.
            std.debug.panic("unexpected error opening '\\??\\pipe\\': {t}", .{err});
        };
        errdefer _ = windows.ntdll.NtClose(pipe_device);
        return .{
            .pipe_device = pipe_device,
            .pipe_path = pipe_path,
        };
    }
    fn deinit(wp: *const Win32Pipe) void {
        _ = windows.ntdll.NtClose(wp.pipe_device);
    }
    fn acquire(wp: *const Win32Pipe) AcquireError!Token {
        const pipe_basename_offset = std.unicode.wtf8ToWtf16LeStringLiteral("\\??\\pipe\\").len;
        const handle = while (true) {
            if (windows.OpenFile(wp.pipe_path, .{
                .access_mask = .{ .STANDARD = .{ .SYNCHRONIZE = true } },
                .creation = .OPEN,
                .share_access = .{},
            })) |handle| {
                return .{ .win32pipe = handle };
            } else |err| switch (err) {
                error.PipeBusy, error.NoDevice => {},

                error.IsDir,
                error.FileNotFound,
                error.NameTooLong,
                error.AntivirusInterference,
                error.BadPathName,
                => return error.ServerFailed,

                error.AccessDenied,
                error.Unexpected,
                => |e| return e,

                error.NotDir => unreachable, // we're not opening as a directory
                error.PathAlreadyExists => unreachable, // we're not trying to create the path
                error.WouldBlock => unreachable, // we're not using overlapped I/O
                error.NetworkNotFound => unreachable, // we're not accessing a network device
            }
            const fpwfb: windows.FILE.PIPE.WAIT_FOR_BUFFER = .init(.{
                .Timeout = windows.FILE.PIPE.WAIT_FOR_BUFFER.WAIT_FOREVER,
                .Name = wp.pipe_path[pipe_basename_offset..],
            });
            windows.DeviceIoControl(
                wp.pipe_device,
                windows.FSCTL.PIPE.WAIT,
                .{ .in = fpwfb.toBuffer() },
            ) catch |err| switch (err) {
                error.UnrecognizedVolume => unreachable, // not a volume
                error.Pending => unreachable, // not using overlapped I/O
                error.PipeClosing => return error.ServerFailed,
                error.PipeAlreadyConnected => unreachable,
                error.PipeAlreadyListening => unreachable,
                error.Unexpected, error.AccessDenied => |e| return e,
            };
            continue;
        };
        return .{ .win32pipe = handle };
    }
};

const builtin = @import("builtin");

const std = @import("../std.zig");
const Allocator = std.mem.Allocator;
const job = std.job;
const windows = std.os.windows;

const Client = @This();
