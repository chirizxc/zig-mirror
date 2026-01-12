const Debug = @This();

impl: Io,

/// It is safe for this to be a `std.Thread.Mutex` because it does not guard any
/// `Io` operations, only data structure accesses. Using an `Io.Mutex` would be
/// undesirable as it may significantly change the scheduling behavior of the
/// application.
mutex: std.Thread.Mutex,

gpa: Allocator,
oom_count: u32,
open_files: std.AutoArrayHashMapUnmanaged(Io.File.Handle, StackTrace) = .empty,
open_dirs: std.AutoArrayHashMapUnmanaged(Io.Dir.Handle, StackTrace) = .empty,

const StackTrace = struct { index: usize, buf: [6]usize };

pub fn init(impl: Io, gpa: Allocator) Debug {
    return .{
        .impl = impl,
        .mutex = .{},
        .gpa = gpa,
        .oom_count = 0,
        .open_files = .empty,
        .open_dirs = .empty,
    };
}

pub fn deinit(dbg: *Debug) void {
    if (dbg.oom_count > 0) {
        std.log.warn("ran out of memory to track {d} handles; some leaks may not be detected", .{dbg.oom_count});
    }
    for (dbg.open_files.keys(), dbg.open_files.values()) |handle, *st| {
        std.log.err("file handle '{any}' leaked: {f}", .{
            handle,
            @as(std.debug.FormatStackTrace, .{
                .stack_trace = .{ .instruction_addresses = &st.buf, .index = st.index },
                .terminal_mode = std.log.terminalMode(),
            }),
        });
    }
    for (dbg.open_dirs.keys(), dbg.open_dirs.values()) |handle, *st| {
        std.log.err("dir handle '{any}' leaked: {f}", .{
            handle,
            @as(std.debug.FormatStackTrace, .{
                .stack_trace = .{ .instruction_addresses = &st.buf, .index = st.index },
                .terminal_mode = std.log.terminalMode(),
            }),
        });
    }
    dbg.open_files.deinit(dbg.gpa);
    dbg.open_dirs.deinit(dbg.gpa);
}

pub fn io(dbg: *Debug) Io {
    return .{
        .userdata = dbg,
        .vtable = &.{
            .async = &async,
            .concurrent = &concurrent,
            .await = &await,
            .cancel = &cancel,
            .select = &select,

            .groupAsync = &groupAsync,
            .groupConcurrent = &groupConcurrent,
            .groupAwait = &groupAwait,
            .groupCancel = &groupCancel,

            .recancel = &recancel,
            .swapCancelProtection = &swapCancelProtection,
            .checkCancel = &checkCancel,

            .futexWait = &futexWait,
            .futexWaitUncancelable = &futexWaitUncancelable,
            .futexWake = &futexWake,

            .dirCreateDir = &dirCreateDir,
            .dirCreateDirPath = &dirCreateDirPath,
            .dirCreateDirPathOpen = &dirCreateDirPathOpen,
            .dirOpenDir = &dirOpenDir,
            .dirStat = &dirStat,
            .dirStatFile = &dirStatFile,
            .dirAccess = &dirAccess,
            .dirCreateFile = &dirCreateFile,
            .dirCreateFileAtomic = &dirCreateFileAtomic,
            .dirOpenFile = &dirOpenFile,
            .dirClose = &dirClose,
            .dirRead = &dirRead,
            .dirRealPath = &dirRealPath,
            .dirRealPathFile = &dirRealPathFile,
            .dirDeleteFile = &dirDeleteFile,
            .dirDeleteDir = &dirDeleteDir,
            .dirRename = &dirRename,
            .dirRenamePreserve = &dirRenamePreserve,
            .dirSymLink = &dirSymLink,
            .dirReadLink = &dirReadLink,
            .dirSetOwner = &dirSetOwner,
            .dirSetFileOwner = &dirSetFileOwner,
            .dirSetPermissions = &dirSetPermissions,
            .dirSetFilePermissions = &dirSetFilePermissions,
            .dirSetTimestamps = &dirSetTimestamps,
            .dirHardLink = &dirHardLink,

            .fileStat = &fileStat,
            .fileLength = &fileLength,
            .fileClose = &fileClose,
            .fileWriteStreaming = &fileWriteStreaming,
            .fileWritePositional = &fileWritePositional,
            .fileWriteFileStreaming = &fileWriteFileStreaming,
            .fileWriteFilePositional = &fileWriteFilePositional,
            .fileReadStreaming = &fileReadStreaming,
            .fileReadPositional = &fileReadPositional,
            .fileSeekBy = &fileSeekBy,
            .fileSeekTo = &fileSeekTo,
            .fileSync = &fileSync,
            .fileIsTty = &fileIsTty,
            .fileEnableAnsiEscapeCodes = &fileEnableAnsiEscapeCodes,
            .fileSupportsAnsiEscapeCodes = &fileSupportsAnsiEscapeCodes,
            .fileSetLength = &fileSetLength,
            .fileSetOwner = &fileSetOwner,
            .fileSetPermissions = &fileSetPermissions,
            .fileSetTimestamps = &fileSetTimestamps,
            .fileLock = &fileLock,
            .fileTryLock = &fileTryLock,
            .fileUnlock = &fileUnlock,
            .fileDowngradeLock = &fileDowngradeLock,
            .fileRealPath = &fileRealPath,
            .fileHardLink = &fileHardLink,

            .processExecutableOpen = &processExecutableOpen,
            .processExecutablePath = &processExecutablePath,
            .lockStderr = &lockStderr,
            .tryLockStderr = &tryLockStderr,
            .unlockStderr = &unlockStderr,
            .processSetCurrentDir = &processSetCurrentDir,
            .processReplace = &processReplace,
            .processReplacePath = &processReplacePath,
            .processSpawn = &processSpawn,
            .processSpawnPath = &processSpawnPath,
            .childWait = &childWait,
            .childKill = &childKill,

            .progressParentFile = &progressParentFile,

            .now = &now,
            .sleep = &sleep,

            .random = &random,
            .randomSecure = &randomSecure,

            .netListenIp = &netListenIp,
            .netAccept = &netAccept,
            .netBindIp = &netBindIp,
            .netConnectIp = &netConnectIp,
            .netListenUnix = &netListenUnix,
            .netConnectUnix = &netConnectUnix,
            .netSend = &netSend,
            .netReceive = &netReceive,

            .netRead = &netRead,
            .netWrite = &netWrite,
            .netWriteFile = &netWriteFile,
            .netClose = &netClose,
            .netShutdown = &netShutdown,
            .netInterfaceNameResolve = &netInterfaceNameResolve,
            .netInterfaceName = &netInterfaceName,
            .netLookup = &netLookup,
        },
    };
}

fn trackOpenFile(dbg: *Debug, file: Io.File, ra: usize) void {
    dbg.mutex.lock();
    defer dbg.mutex.unlock();
    const gop = dbg.open_files.getOrPut(dbg.gpa, file.handle) catch |err| switch (err) {
        error.OutOfMemory => {
            dbg.oom_count += 1;
            return;
        },
    };
    assert(!gop.found_existing); // underlying implementation returned duplicate handle
    const st = std.debug.captureCurrentStackTrace(.{ .first_address = ra }, &gop.value_ptr.buf);
    gop.value_ptr.index = st.index;
}

fn trackCloseFile(dbg: *Debug, file: Io.File, ra: usize) void {
    dbg.mutex.lock();
    defer dbg.mutex.unlock();
    if (!dbg.open_files.swapRemove(file.handle)) {
        // If there was an OOM we might have failed to track the handle, but otherwise this is
        // definitely incorrect usage.
        if (dbg.oom_count == 0) {
            std.debug.panicExtra(ra, "attempted to close file handle '{any}' which is not open", .{file.handle});
        }
    }
}

fn trackOpenDir(dbg: *Debug, dir: Io.Dir, ra: usize) void {
    dbg.mutex.lock();
    defer dbg.mutex.unlock();
    const gop = dbg.open_dirs.getOrPut(dbg.gpa, dir.handle) catch |err| switch (err) {
        error.OutOfMemory => {
            dbg.oom_count += 1;
            return;
        },
    };
    assert(!gop.found_existing); // underlying implementation returned duplicate handle
    const st = std.debug.captureCurrentStackTrace(.{ .first_address = ra }, &gop.value_ptr.buf);
    gop.value_ptr.index = st.index;
}

fn trackCloseDir(dbg: *Debug, dir: Io.Dir, ra: usize) void {
    dbg.mutex.lock();
    defer dbg.mutex.unlock();
    if (!dbg.open_dirs.swapRemove(dir.handle)) {
        // If there was an OOM we might have failed to track the handle, but otherwise this is
        // definitely incorrect usage.
        if (dbg.oom_count == 0) {
            std.debug.panicExtra(ra, "attempted to close dir handle '{any}' which is not open", .{dir.handle});
        }
    }
}

fn async(userdata: ?*anyopaque, result: []u8, result_alignment: std.mem.Alignment, context: []const u8, context_alignment: std.mem.Alignment, start: *const fn (context: *const anyopaque, result: *anyopaque) void) ?*Io.AnyFuture {
    const dbg: *Debug = @ptrCast(@alignCast(userdata));
    return dbg.impl.vtable.async(dbg.impl.userdata, result, result_alignment, context, context_alignment, start);
}

fn concurrent(userdata: ?*anyopaque, result_len: usize, result_alignment: std.mem.Alignment, context: []const u8, context_alignment: std.mem.Alignment, start: *const fn (context: *const anyopaque, result: *anyopaque) void) Io.ConcurrentError!*Io.AnyFuture {
    const dbg: *Debug = @ptrCast(@alignCast(userdata));
    return dbg.impl.vtable.concurrent(dbg.impl.userdata, result_len, result_alignment, context, context_alignment, start);
}

fn await(userdata: ?*anyopaque, any_future: *Io.AnyFuture, result: []u8, result_alignment: std.mem.Alignment) void {
    const dbg: *Debug = @ptrCast(@alignCast(userdata));
    return dbg.impl.vtable.await(dbg.impl.userdata, any_future, result, result_alignment);
}

fn cancel(userdata: ?*anyopaque, any_future: *Io.AnyFuture, result: []u8, result_alignment: std.mem.Alignment) void {
    const dbg: *Debug = @ptrCast(@alignCast(userdata));
    return dbg.impl.vtable.cancel(dbg.impl.userdata, any_future, result, result_alignment);
}

fn groupAsync(userdata: ?*anyopaque, group: *Io.Group, context: []const u8, context_alignment: std.mem.Alignment, start: *const fn (context: *const anyopaque) Cancelable!void) void {
    const dbg: *Debug = @ptrCast(@alignCast(userdata));
    return dbg.impl.vtable.groupAsync(dbg.impl.userdata, group, context, context_alignment, start);
}

fn groupConcurrent(userdata: ?*anyopaque, group: *Io.Group, context: []const u8, context_alignment: std.mem.Alignment, start: *const fn (context: *const anyopaque) Cancelable!void) Io.ConcurrentError!void {
    const dbg: *Debug = @ptrCast(@alignCast(userdata));
    return dbg.impl.vtable.groupConcurrent(dbg.impl.userdata, group, context, context_alignment, start);
}
fn groupAwait(userdata: ?*anyopaque, group: *Io.Group, token: *anyopaque) Cancelable!void {
    const dbg: *Debug = @ptrCast(@alignCast(userdata));
    return dbg.impl.vtable.groupAwait(dbg.impl.userdata, group, token);
}
fn groupCancel(userdata: ?*anyopaque, group: *Io.Group, token: *anyopaque) void {
    const dbg: *Debug = @ptrCast(@alignCast(userdata));
    return dbg.impl.vtable.groupCancel(dbg.impl.userdata, group, token);
}

fn recancel(userdata: ?*anyopaque) void {
    const dbg: *Debug = @ptrCast(@alignCast(userdata));
    return dbg.impl.vtable.recancel(dbg.impl.userdata);
}
fn swapCancelProtection(userdata: ?*anyopaque, new: Io.CancelProtection) Io.CancelProtection {
    const dbg: *Debug = @ptrCast(@alignCast(userdata));
    return dbg.impl.vtable.swapCancelProtection(dbg.impl.userdata, new);
}
fn checkCancel(userdata: ?*anyopaque) Cancelable!void {
    const dbg: *Debug = @ptrCast(@alignCast(userdata));
    return dbg.impl.vtable.checkCancel(dbg.impl.userdata);
}

fn select(userdata: ?*anyopaque, futures: []const *Io.AnyFuture) Cancelable!usize {
    const dbg: *Debug = @ptrCast(@alignCast(userdata));
    return dbg.impl.vtable.select(dbg.impl.userdata, futures);
}

fn futexWait(userdata: ?*anyopaque, ptr: *const u32, expected: u32, timeout: Io.Timeout) Cancelable!void {
    const dbg: *Debug = @ptrCast(@alignCast(userdata));
    return dbg.impl.vtable.futexWait(dbg.impl.userdata, ptr, expected, timeout);
}
fn futexWaitUncancelable(userdata: ?*anyopaque, ptr: *const u32, expected: u32) void {
    const dbg: *Debug = @ptrCast(@alignCast(userdata));
    return dbg.impl.vtable.futexWaitUncancelable(dbg.impl.userdata, ptr, expected);
}
fn futexWake(userdata: ?*anyopaque, ptr: *const u32, max_waiters: u32) void {
    const dbg: *Debug = @ptrCast(@alignCast(userdata));
    return dbg.impl.vtable.futexWake(dbg.impl.userdata, ptr, max_waiters);
}

fn dirCreateDir(userdata: ?*anyopaque, dir: Io.Dir, sub_path: []const u8, permissions: Io.Dir.Permissions) Io.Dir.CreateDirError!void {
    const dbg: *Debug = @ptrCast(@alignCast(userdata));
    return dbg.impl.vtable.dirCreateDir(dbg.impl.userdata, dir, sub_path, permissions);
}
fn dirCreateDirPath(userdata: ?*anyopaque, dir: Io.Dir, sub_path: []const u8, permissions: Io.Dir.Permissions) Io.Dir.CreateDirPathError!Io.Dir.CreatePathStatus {
    const dbg: *Debug = @ptrCast(@alignCast(userdata));
    return dbg.impl.vtable.dirCreateDirPath(dbg.impl.userdata, dir, sub_path, permissions);
}
fn dirCreateDirPathOpen(userdata: ?*anyopaque, dir: Io.Dir, sub_path: []const u8, permissions: Io.Dir.Permissions, options: Io.Dir.OpenOptions) Io.Dir.CreateDirPathOpenError!Io.Dir {
    const dbg: *Debug = @ptrCast(@alignCast(userdata));
    const new_dir = try dbg.impl.vtable.dirCreateDirPathOpen(dbg.impl.userdata, dir, sub_path, permissions, options);
    dbg.trackOpenDir(new_dir, @returnAddress());
    return new_dir;
}
fn dirOpenDir(userdata: ?*anyopaque, dir: Io.Dir, sub_path: []const u8, options: Io.Dir.OpenOptions) Io.Dir.OpenError!Io.Dir {
    const dbg: *Debug = @ptrCast(@alignCast(userdata));
    const new_dir = try dbg.impl.vtable.dirOpenDir(dbg.impl.userdata, dir, sub_path, options);
    dbg.trackOpenDir(new_dir, @returnAddress());
    return new_dir;
}
fn dirStat(userdata: ?*anyopaque, dir: Io.Dir) Io.Dir.StatError!Io.Dir.Stat {
    const dbg: *Debug = @ptrCast(@alignCast(userdata));
    return dbg.impl.vtable.dirStat(dbg.impl.userdata, dir);
}
fn dirStatFile(userdata: ?*anyopaque, dir: Io.Dir, sub_path: []const u8, options: Io.Dir.StatFileOptions) Io.Dir.StatFileError!Io.File.Stat {
    const dbg: *Debug = @ptrCast(@alignCast(userdata));
    return dbg.impl.vtable.dirStatFile(dbg.impl.userdata, dir, sub_path, options);
}
fn dirAccess(userdata: ?*anyopaque, dir: Io.Dir, sub_path: []const u8, options: Io.Dir.AccessOptions) Io.Dir.AccessError!void {
    const dbg: *Debug = @ptrCast(@alignCast(userdata));
    return dbg.impl.vtable.dirAccess(dbg.impl.userdata, dir, sub_path, options);
}
fn dirCreateFile(userdata: ?*anyopaque, dir: Io.Dir, sub_path: []const u8, flags: Io.File.CreateFlags) Io.File.OpenError!Io.File {
    const dbg: *Debug = @ptrCast(@alignCast(userdata));
    const file = try dbg.impl.vtable.dirCreateFile(dbg.impl.userdata, dir, sub_path, flags);
    dbg.trackOpenFile(file, @returnAddress());
    return file;
}
fn dirCreateFileAtomic(userdata: ?*anyopaque, dir: Io.Dir, sub_path: []const u8, options: Io.Dir.CreateFileAtomicOptions) Io.Dir.CreateFileAtomicError!Io.File.Atomic {
    const dbg: *Debug = @ptrCast(@alignCast(userdata));
    const af = try dbg.impl.vtable.dirCreateFileAtomic(dbg.impl.userdata, dir, sub_path, options);
    if (af.file_open) dbg.trackOpenFile(af.file, @returnAddress());
    return af;
}
fn dirOpenFile(userdata: ?*anyopaque, dir: Io.Dir, sub_path: []const u8, flags: Io.File.OpenFlags) Io.File.OpenError!Io.File {
    const dbg: *Debug = @ptrCast(@alignCast(userdata));
    const file = try dbg.impl.vtable.dirOpenFile(dbg.impl.userdata, dir, sub_path, flags);
    dbg.trackOpenFile(file, @returnAddress());
    return file;
}
fn dirClose(userdata: ?*anyopaque, dirs: []const Io.Dir) void {
    const dbg: *Debug = @ptrCast(@alignCast(userdata));
    for (dirs) |dir| dbg.trackCloseDir(dir, @returnAddress());
    return dbg.impl.vtable.dirClose(dbg.impl.userdata, dirs);
}
fn dirRead(userdata: ?*anyopaque, dr: *Io.Dir.Reader, buffer: []Io.Dir.Entry) Io.Dir.Reader.Error!usize {
    const dbg: *Debug = @ptrCast(@alignCast(userdata));
    return dbg.impl.vtable.dirRead(dbg.impl.userdata, dr, buffer);
}
fn dirRealPath(userdata: ?*anyopaque, dir: Io.Dir, out_buffer: []u8) Io.Dir.RealPathError!usize {
    const dbg: *Debug = @ptrCast(@alignCast(userdata));
    return dbg.impl.vtable.dirRealPath(dbg.impl.userdata, dir, out_buffer);
}
fn dirRealPathFile(userdata: ?*anyopaque, dir: Io.Dir, path_name: []const u8, out_buffer: []u8) Io.Dir.RealPathFileError!usize {
    const dbg: *Debug = @ptrCast(@alignCast(userdata));
    return dbg.impl.vtable.dirRealPathFile(dbg.impl.userdata, dir, path_name, out_buffer);
}
fn dirDeleteFile(userdata: ?*anyopaque, dir: Io.Dir, sub_path: []const u8) Io.Dir.DeleteFileError!void {
    const dbg: *Debug = @ptrCast(@alignCast(userdata));
    return dbg.impl.vtable.dirDeleteFile(dbg.impl.userdata, dir, sub_path);
}
fn dirDeleteDir(userdata: ?*anyopaque, dir: Io.Dir, sub_path: []const u8) Io.Dir.DeleteDirError!void {
    const dbg: *Debug = @ptrCast(@alignCast(userdata));
    return dbg.impl.vtable.dirDeleteDir(dbg.impl.userdata, dir, sub_path);
}
fn dirRename(userdata: ?*anyopaque, old_dir: Io.Dir, old_sub_path: []const u8, new_dir: Io.Dir, new_sub_path: []const u8) Io.Dir.RenameError!void {
    const dbg: *Debug = @ptrCast(@alignCast(userdata));
    return dbg.impl.vtable.dirRename(dbg.impl.userdata, old_dir, old_sub_path, new_dir, new_sub_path);
}
fn dirRenamePreserve(userdata: ?*anyopaque, old_dir: Io.Dir, old_sub_path: []const u8, new_dir: Io.Dir, new_sub_path: []const u8) Io.Dir.RenamePreserveError!void {
    const dbg: *Debug = @ptrCast(@alignCast(userdata));
    return dbg.impl.vtable.dirRenamePreserve(dbg.impl.userdata, old_dir, old_sub_path, new_dir, new_sub_path);
}
fn dirSymLink(userdata: ?*anyopaque, dir: Io.Dir, target_path: []const u8, sym_link_path: []const u8, flags: Io.Dir.SymLinkFlags) Io.Dir.SymLinkError!void {
    const dbg: *Debug = @ptrCast(@alignCast(userdata));
    return dbg.impl.vtable.dirSymLink(dbg.impl.userdata, dir, target_path, sym_link_path, flags);
}
fn dirReadLink(userdata: ?*anyopaque, dir: Io.Dir, sub_path: []const u8, buffer: []u8) Io.Dir.ReadLinkError!usize {
    const dbg: *Debug = @ptrCast(@alignCast(userdata));
    return dbg.impl.vtable.dirReadLink(dbg.impl.userdata, dir, sub_path, buffer);
}
fn dirSetOwner(userdata: ?*anyopaque, dir: Io.Dir, uid: ?Io.File.Uid, gid: ?Io.File.Gid) Io.Dir.SetOwnerError!void {
    const dbg: *Debug = @ptrCast(@alignCast(userdata));
    return dbg.impl.vtable.dirSetOwner(dbg.impl.userdata, dir, uid, gid);
}
fn dirSetFileOwner(userdata: ?*anyopaque, dir: Io.Dir, sub_path: []const u8, uid: ?Io.File.Uid, gid: ?Io.File.Gid, options: Io.Dir.SetFileOwnerOptions) Io.Dir.SetFileOwnerError!void {
    const dbg: *Debug = @ptrCast(@alignCast(userdata));
    return dbg.impl.vtable.dirSetFileOwner(dbg.impl.userdata, dir, sub_path, uid, gid, options);
}
fn dirSetPermissions(userdata: ?*anyopaque, dir: Io.Dir, permissions: Io.Dir.Permissions) Io.Dir.SetPermissionsError!void {
    const dbg: *Debug = @ptrCast(@alignCast(userdata));
    return dbg.impl.vtable.dirSetPermissions(dbg.impl.userdata, dir, permissions);
}
fn dirSetFilePermissions(userdata: ?*anyopaque, dir: Io.Dir, sub_path: []const u8, permissions: Io.File.Permissions, options: Io.Dir.SetFilePermissionsOptions) Io.Dir.SetFilePermissionsError!void {
    const dbg: *Debug = @ptrCast(@alignCast(userdata));
    return dbg.impl.vtable.dirSetFilePermissions(dbg.impl.userdata, dir, sub_path, permissions, options);
}
fn dirSetTimestamps(userdata: ?*anyopaque, dir: Io.Dir, sub_path: []const u8, options: Io.Dir.SetTimestampsOptions) Io.Dir.SetTimestampsError!void {
    const dbg: *Debug = @ptrCast(@alignCast(userdata));
    return dbg.impl.vtable.dirSetTimestamps(dbg.impl.userdata, dir, sub_path, options);
}
fn dirHardLink(userdata: ?*anyopaque, old_dir: Io.Dir, old_sub_path: []const u8, new_dir: Io.Dir, new_sub_path: []const u8, options: Io.Dir.HardLinkOptions) Io.Dir.HardLinkError!void {
    const dbg: *Debug = @ptrCast(@alignCast(userdata));
    return dbg.impl.vtable.dirHardLink(dbg.impl.userdata, old_dir, old_sub_path, new_dir, new_sub_path, options);
}

fn fileStat(userdata: ?*anyopaque, file: Io.File) Io.File.StatError!Io.File.Stat {
    const dbg: *Debug = @ptrCast(@alignCast(userdata));
    return dbg.impl.vtable.fileStat(dbg.impl.userdata, file);
}
fn fileLength(userdata: ?*anyopaque, file: Io.File) Io.File.LengthError!u64 {
    const dbg: *Debug = @ptrCast(@alignCast(userdata));
    return dbg.impl.vtable.fileLength(dbg.impl.userdata, file);
}
fn fileClose(userdata: ?*anyopaque, files: []const Io.File) void {
    const dbg: *Debug = @ptrCast(@alignCast(userdata));
    for (files) |file| dbg.trackCloseFile(file, @returnAddress());
    return dbg.impl.vtable.fileClose(dbg.impl.userdata, files);
}
fn fileWriteStreaming(userdata: ?*anyopaque, file: Io.File, header: []const u8, data: []const []const u8, splat: usize) Io.File.Writer.Error!usize {
    const dbg: *Debug = @ptrCast(@alignCast(userdata));
    return dbg.impl.vtable.fileWriteStreaming(dbg.impl.userdata, file, header, data, splat);
}
fn fileWritePositional(userdata: ?*anyopaque, file: Io.File, header: []const u8, data: []const []const u8, splat: usize, offset: u64) Io.File.WritePositionalError!usize {
    const dbg: *Debug = @ptrCast(@alignCast(userdata));
    return dbg.impl.vtable.fileWritePositional(dbg.impl.userdata, file, header, data, splat, offset);
}
fn fileWriteFileStreaming(userdata: ?*anyopaque, file: Io.File, header: []const u8, fr: *Io.File.Reader, limit: Io.Limit) Io.File.Writer.WriteFileError!usize {
    const dbg: *Debug = @ptrCast(@alignCast(userdata));
    return dbg.impl.vtable.fileWriteFileStreaming(dbg.impl.userdata, file, header, fr, limit);
}
fn fileWriteFilePositional(userdata: ?*anyopaque, file: Io.File, header: []const u8, fr: *Io.File.Reader, limit: Io.Limit, offset: u64) Io.File.WriteFilePositionalError!usize {
    const dbg: *Debug = @ptrCast(@alignCast(userdata));
    return dbg.impl.vtable.fileWriteFilePositional(dbg.impl.userdata, file, header, fr, limit, offset);
}

fn fileReadStreaming(userdata: ?*anyopaque, file: Io.File, data: []const []u8) Io.File.Reader.Error!usize {
    const dbg: *Debug = @ptrCast(@alignCast(userdata));
    return dbg.impl.vtable.fileReadStreaming(dbg.impl.userdata, file, data);
}

fn fileReadPositional(userdata: ?*anyopaque, file: Io.File, data: []const []u8, offset: u64) Io.File.ReadPositionalError!usize {
    const dbg: *Debug = @ptrCast(@alignCast(userdata));
    return dbg.impl.vtable.fileReadPositional(dbg.impl.userdata, file, data, offset);
}
fn fileSeekBy(userdata: ?*anyopaque, file: Io.File, relative_offset: i64) Io.File.SeekError!void {
    const dbg: *Debug = @ptrCast(@alignCast(userdata));
    return dbg.impl.vtable.fileSeekBy(dbg.impl.userdata, file, relative_offset);
}
fn fileSeekTo(userdata: ?*anyopaque, file: Io.File, absolute_offset: u64) Io.File.SeekError!void {
    const dbg: *Debug = @ptrCast(@alignCast(userdata));
    return dbg.impl.vtable.fileSeekTo(dbg.impl.userdata, file, absolute_offset);
}
fn fileSync(userdata: ?*anyopaque, file: Io.File) Io.File.SyncError!void {
    const dbg: *Debug = @ptrCast(@alignCast(userdata));
    return dbg.impl.vtable.fileSync(dbg.impl.userdata, file);
}
fn fileIsTty(userdata: ?*anyopaque, file: Io.File) Cancelable!bool {
    const dbg: *Debug = @ptrCast(@alignCast(userdata));
    return dbg.impl.vtable.fileIsTty(dbg.impl.userdata, file);
}
fn fileEnableAnsiEscapeCodes(userdata: ?*anyopaque, file: Io.File) Io.File.EnableAnsiEscapeCodesError!void {
    const dbg: *Debug = @ptrCast(@alignCast(userdata));
    return dbg.impl.vtable.fileEnableAnsiEscapeCodes(dbg.impl.userdata, file);
}
fn fileSupportsAnsiEscapeCodes(userdata: ?*anyopaque, file: Io.File) Cancelable!bool {
    const dbg: *Debug = @ptrCast(@alignCast(userdata));
    return dbg.impl.vtable.fileSupportsAnsiEscapeCodes(dbg.impl.userdata, file);
}
fn fileSetLength(userdata: ?*anyopaque, file: Io.File, length: u64) Io.File.SetLengthError!void {
    const dbg: *Debug = @ptrCast(@alignCast(userdata));
    return dbg.impl.vtable.fileSetLength(dbg.impl.userdata, file, length);
}
fn fileSetOwner(userdata: ?*anyopaque, file: Io.File, uid: ?Io.File.Uid, gid: ?Io.File.Gid) Io.File.SetOwnerError!void {
    const dbg: *Debug = @ptrCast(@alignCast(userdata));
    return dbg.impl.vtable.fileSetOwner(dbg.impl.userdata, file, uid, gid);
}
fn fileSetPermissions(userdata: ?*anyopaque, file: Io.File, permissions: Io.File.Permissions) Io.File.SetPermissionsError!void {
    const dbg: *Debug = @ptrCast(@alignCast(userdata));
    return dbg.impl.vtable.fileSetPermissions(dbg.impl.userdata, file, permissions);
}
fn fileSetTimestamps(userdata: ?*anyopaque, file: Io.File, options: Io.File.SetTimestampsOptions) Io.File.SetTimestampsError!void {
    const dbg: *Debug = @ptrCast(@alignCast(userdata));
    return dbg.impl.vtable.fileSetTimestamps(dbg.impl.userdata, file, options);
}
fn fileLock(userdata: ?*anyopaque, file: Io.File, lock: Io.File.Lock) Io.File.LockError!void {
    const dbg: *Debug = @ptrCast(@alignCast(userdata));
    return dbg.impl.vtable.fileLock(dbg.impl.userdata, file, lock);
}
fn fileTryLock(userdata: ?*anyopaque, file: Io.File, lock: Io.File.Lock) Io.File.LockError!bool {
    const dbg: *Debug = @ptrCast(@alignCast(userdata));
    return dbg.impl.vtable.fileTryLock(dbg.impl.userdata, file, lock);
}
fn fileUnlock(userdata: ?*anyopaque, file: Io.File) void {
    const dbg: *Debug = @ptrCast(@alignCast(userdata));
    return dbg.impl.vtable.fileUnlock(dbg.impl.userdata, file);
}
fn fileDowngradeLock(userdata: ?*anyopaque, file: Io.File) Io.File.DowngradeLockError!void {
    const dbg: *Debug = @ptrCast(@alignCast(userdata));
    return dbg.impl.vtable.fileDowngradeLock(dbg.impl.userdata, file);
}
fn fileRealPath(userdata: ?*anyopaque, file: Io.File, out_buffer: []u8) Io.File.RealPathError!usize {
    const dbg: *Debug = @ptrCast(@alignCast(userdata));
    return dbg.impl.vtable.fileRealPath(dbg.impl.userdata, file, out_buffer);
}
fn fileHardLink(userdata: ?*anyopaque, file: Io.File, dir: Io.Dir, sub_path: []const u8, options: Io.File.HardLinkOptions) Io.File.HardLinkError!void {
    const dbg: *Debug = @ptrCast(@alignCast(userdata));
    return dbg.impl.vtable.fileHardLink(dbg.impl.userdata, file, dir, sub_path, options);
}

fn processExecutableOpen(userdata: ?*anyopaque, flags: Io.File.OpenFlags) std.process.OpenExecutableError!Io.File {
    const dbg: *Debug = @ptrCast(@alignCast(userdata));
    const file = try dbg.impl.vtable.processExecutableOpen(dbg.impl.userdata, flags);
    dbg.trackOpenFile(file, @returnAddress());
    return file;
}
fn processExecutablePath(userdata: ?*anyopaque, buffer: []u8) std.process.ExecutablePathError!usize {
    const dbg: *Debug = @ptrCast(@alignCast(userdata));
    return dbg.impl.vtable.processExecutablePath(dbg.impl.userdata, buffer);
}
fn lockStderr(userdata: ?*anyopaque, mode: ?Io.Terminal.Mode) Cancelable!Io.LockedStderr {
    const dbg: *Debug = @ptrCast(@alignCast(userdata));
    return dbg.impl.vtable.lockStderr(dbg.impl.userdata, mode);
}
fn tryLockStderr(userdata: ?*anyopaque, mode: ?Io.Terminal.Mode) Cancelable!?Io.LockedStderr {
    const dbg: *Debug = @ptrCast(@alignCast(userdata));
    return dbg.impl.vtable.tryLockStderr(dbg.impl.userdata, mode);
}
fn unlockStderr(userdata: ?*anyopaque) void {
    const dbg: *Debug = @ptrCast(@alignCast(userdata));
    return dbg.impl.vtable.unlockStderr(dbg.impl.userdata);
}
fn processSetCurrentDir(userdata: ?*anyopaque, dir: Io.Dir) std.process.SetCurrentDirError!void {
    const dbg: *Debug = @ptrCast(@alignCast(userdata));
    return dbg.impl.vtable.processSetCurrentDir(dbg.impl.userdata, dir);
}
fn processReplace(userdata: ?*anyopaque, options: std.process.ReplaceOptions) std.process.ReplaceError {
    const dbg: *Debug = @ptrCast(@alignCast(userdata));
    return dbg.impl.vtable.processReplace(dbg.impl.userdata, options);
}
fn processReplacePath(userdata: ?*anyopaque, dir: Io.Dir, options: std.process.ReplaceOptions) std.process.ReplaceError {
    const dbg: *Debug = @ptrCast(@alignCast(userdata));
    return dbg.impl.vtable.processReplacePath(dbg.impl.userdata, dir, options);
}
fn processSpawn(userdata: ?*anyopaque, options: std.process.SpawnOptions) std.process.SpawnError!std.process.Child {
    const dbg: *Debug = @ptrCast(@alignCast(userdata));
    return dbg.impl.vtable.processSpawn(dbg.impl.userdata, options);
}
fn processSpawnPath(userdata: ?*anyopaque, dir: Io.Dir, options: std.process.SpawnOptions) std.process.SpawnError!std.process.Child {
    const dbg: *Debug = @ptrCast(@alignCast(userdata));
    return dbg.impl.vtable.processSpawnPath(dbg.impl.userdata, dir, options);
}
fn childWait(userdata: ?*anyopaque, child: *std.process.Child) std.process.Child.WaitError!std.process.Child.Term {
    const dbg: *Debug = @ptrCast(@alignCast(userdata));
    return dbg.impl.vtable.childWait(dbg.impl.userdata, child);
}
fn childKill(userdata: ?*anyopaque, child: *std.process.Child) void {
    const dbg: *Debug = @ptrCast(@alignCast(userdata));
    return dbg.impl.vtable.childKill(dbg.impl.userdata, child);
}

fn progressParentFile(userdata: ?*anyopaque) std.Progress.ParentFileError!Io.File {
    const dbg: *Debug = @ptrCast(@alignCast(userdata));
    return dbg.impl.vtable.progressParentFile(dbg.impl.userdata);
}

fn now(userdata: ?*anyopaque, clock: Io.Clock) Io.Clock.Error!Io.Timestamp {
    const dbg: *Debug = @ptrCast(@alignCast(userdata));
    return dbg.impl.vtable.now(dbg.impl.userdata, clock);
}
fn sleep(userdata: ?*anyopaque, timeout: Io.Timeout) Io.SleepError!void {
    const dbg: *Debug = @ptrCast(@alignCast(userdata));
    return dbg.impl.vtable.sleep(dbg.impl.userdata, timeout);
}

fn random(userdata: ?*anyopaque, buffer: []u8) void {
    const dbg: *Debug = @ptrCast(@alignCast(userdata));
    return dbg.impl.vtable.random(dbg.impl.userdata, buffer);
}
fn randomSecure(userdata: ?*anyopaque, buffer: []u8) Io.RandomSecureError!void {
    const dbg: *Debug = @ptrCast(@alignCast(userdata));
    return dbg.impl.vtable.randomSecure(dbg.impl.userdata, buffer);
}

fn netListenIp(userdata: ?*anyopaque, address: net.IpAddress, options: net.IpAddress.ListenOptions) net.IpAddress.ListenError!net.Server {
    const dbg: *Debug = @ptrCast(@alignCast(userdata));
    return dbg.impl.vtable.netListenIp(dbg.impl.userdata, address, options);
}
fn netAccept(userdata: ?*anyopaque, server: net.Socket.Handle) net.Server.AcceptError!net.Stream {
    const dbg: *Debug = @ptrCast(@alignCast(userdata));
    return dbg.impl.vtable.netAccept(dbg.impl.userdata, server);
}
fn netBindIp(userdata: ?*anyopaque, address: *const net.IpAddress, options: net.IpAddress.BindOptions) net.IpAddress.BindError!net.Socket {
    const dbg: *Debug = @ptrCast(@alignCast(userdata));
    return dbg.impl.vtable.netBindIp(dbg.impl.userdata, address, options);
}
fn netConnectIp(userdata: ?*anyopaque, address: *const net.IpAddress, options: net.IpAddress.ConnectOptions) net.IpAddress.ConnectError!net.Stream {
    const dbg: *Debug = @ptrCast(@alignCast(userdata));
    return dbg.impl.vtable.netConnectIp(dbg.impl.userdata, address, options);
}
fn netListenUnix(userdata: ?*anyopaque, address: *const net.UnixAddress, options: net.UnixAddress.ListenOptions) net.UnixAddress.ListenError!net.Socket.Handle {
    const dbg: *Debug = @ptrCast(@alignCast(userdata));
    return dbg.impl.vtable.netListenUnix(dbg.impl.userdata, address, options);
}
fn netConnectUnix(userdata: ?*anyopaque, address: *const net.UnixAddress) net.UnixAddress.ConnectError!net.Socket.Handle {
    const dbg: *Debug = @ptrCast(@alignCast(userdata));
    return dbg.impl.vtable.netConnectUnix(dbg.impl.userdata, address);
}
fn netSend(userdata: ?*anyopaque, handle: net.Socket.Handle, messages: []net.OutgoingMessage, flags: net.SendFlags) struct { ?net.Socket.SendError, usize } {
    const dbg: *Debug = @ptrCast(@alignCast(userdata));
    return dbg.impl.vtable.netSend(dbg.impl.userdata, handle, messages, flags);
}
fn netReceive(userdata: ?*anyopaque, handle: net.Socket.Handle, message_buffer: []net.IncomingMessage, data_buffer: []u8, flags: net.ReceiveFlags, timeout: Io.Timeout) struct { ?net.Socket.ReceiveTimeoutError, usize } {
    const dbg: *Debug = @ptrCast(@alignCast(userdata));
    return dbg.impl.vtable.netReceive(dbg.impl.userdata, handle, message_buffer, data_buffer, flags, timeout);
}

fn netRead(userdata: ?*anyopaque, src: net.Socket.Handle, data: [][]u8) net.Stream.Reader.Error!usize {
    const dbg: *Debug = @ptrCast(@alignCast(userdata));
    return dbg.impl.vtable.netRead(dbg.impl.userdata, src, data);
}
fn netWrite(userdata: ?*anyopaque, dest: net.Socket.Handle, header: []const u8, data: []const []const u8, splat: usize) net.Stream.Writer.Error!usize {
    const dbg: *Debug = @ptrCast(@alignCast(userdata));
    return dbg.impl.vtable.netWrite(dbg.impl.userdata, dest, header, data, splat);
}
fn netWriteFile(userdata: ?*anyopaque, dest: net.Socket.Handle, header: []const u8, fr: *Io.File.Reader, limit: Io.Limit) net.Stream.Writer.WriteFileError!usize {
    const dbg: *Debug = @ptrCast(@alignCast(userdata));
    return dbg.impl.vtable.netWriteFile(dbg.impl.userdata, dest, header, fr, limit);
}
fn netClose(userdata: ?*anyopaque, handle: []const net.Socket.Handle) void {
    const dbg: *Debug = @ptrCast(@alignCast(userdata));
    return dbg.impl.vtable.netClose(dbg.impl.userdata, handle);
}
fn netShutdown(userdata: ?*anyopaque, handle: net.Socket.Handle, how: net.ShutdownHow) net.ShutdownError!void {
    const dbg: *Debug = @ptrCast(@alignCast(userdata));
    return dbg.impl.vtable.netShutdown(dbg.impl.userdata, handle, how);
}
fn netInterfaceNameResolve(userdata: ?*anyopaque, name: *const net.Interface.Name) net.Interface.Name.ResolveError!net.Interface {
    const dbg: *Debug = @ptrCast(@alignCast(userdata));
    return dbg.impl.vtable.netInterfaceNameResolve(dbg.impl.userdata, name);
}
fn netInterfaceName(userdata: ?*anyopaque, interface: net.Interface) net.Interface.NameError!net.Interface.Name {
    const dbg: *Debug = @ptrCast(@alignCast(userdata));
    return dbg.impl.vtable.netInterfaceName(dbg.impl.userdata, interface);
}
fn netLookup(userdata: ?*anyopaque, host_name: net.HostName, resolved: *Io.Queue(net.HostName.LookupResult), options: net.HostName.LookupOptions) net.HostName.LookupError!void {
    const dbg: *Debug = @ptrCast(@alignCast(userdata));
    return dbg.impl.vtable.netLookup(dbg.impl.userdata, host_name, resolved, options);
}

const std = @import("../std.zig");
const Allocator = std.mem.Allocator;
const Cancelable = Io.Cancelable;
const Io = std.Io;
const assert = std.debug.assert;
const net = Io.net;
