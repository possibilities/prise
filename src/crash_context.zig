//! Crash bundle capture for client and server failures.

const std = @import("std");

pub const Role = enum {
    client,
    server,
};

const EVENT_CAPACITY = 128;
const EVENT_BYTES_MAX = 256;
const LOG_TAIL_BYTES_MAX = 8 * 1024;
const LOCK_CONTENTION_NOTE = "snapshot unavailable due to crash_context lock contention";

const EventEntry = struct {
    len: usize = 0,
    bytes: [EVENT_BYTES_MAX]u8 = [_]u8{0} ** EVENT_BYTES_MAX,
};

const Snapshot = struct {
    role: Role,
    version: []const u8,
    reason: []u8,
    snapshot_note: ?[]u8,
    socket_path: ?[]u8,
    session_name: ?[]u8,
    cache_dir_override: ?[]u8,
    pty_validity: ?i64,
    current_pty_id: ?u32,
    events: []u8,

    fn deinit(self: *Snapshot, allocator: std.mem.Allocator) void {
        allocator.free(self.reason);
        if (self.snapshot_note) |value| allocator.free(value);
        if (self.socket_path) |value| allocator.free(value);
        if (self.session_name) |value| allocator.free(value);
        if (self.cache_dir_override) |value| allocator.free(value);
        allocator.free(self.events);
    }
};

const State = struct {
    role: Role,
    version: []const u8,
    mutex: std.Thread.Mutex = .{},
    socket_path: ?[]u8 = null,
    session_name: ?[]u8 = null,
    cache_dir_override: ?[]u8 = null,
    pty_validity: ?i64 = null,
    current_pty_id: ?u32 = null,
    next_event: usize = 0,
    event_count: usize = 0,
    events: [EVENT_CAPACITY]EventEntry = [_]EventEntry{.{}} ** EVENT_CAPACITY,

    fn deinit(self: *State) void {
        if (self.socket_path) |value| std.heap.page_allocator.free(value);
        if (self.session_name) |value| std.heap.page_allocator.free(value);
        if (self.cache_dir_override) |value| std.heap.page_allocator.free(value);
    }
};

/// Global crash-context state.
///
/// This singleton is initialized before worker threads start and deinitialized
/// only after all worker threads have stopped. Public helpers assume `state` is
/// either null or fully initialized; they do not synchronize the transition.
var state: ?State = null;

pub fn init(role: Role, version: []const u8) void {
    deinit();
    state = .{
        .role = role,
        .version = version,
    };
    record("crash context initialized", .{});
}

pub fn deinit() void {
    if (state) |*ctx| {
        ctx.deinit();
    }
    state = null;
}

pub fn setSocketPath(path: []const u8) void {
    setOwnedField(.socket_path, path);
}

pub fn setSessionName(name: ?[]const u8) void {
    if (name) |value| {
        setOwnedField(.session_name, value);
        return;
    }
    clearOwnedField(.session_name);
}

pub fn setCacheDirOverrideForTests(path: ?[]const u8) void {
    if (path) |value| {
        setOwnedField(.cache_dir_override, value);
        return;
    }
    clearOwnedField(.cache_dir_override);
}

pub fn setPtyValidity(value: ?i64) void {
    if (state) |*ctx| {
        ctx.mutex.lock();
        defer ctx.mutex.unlock();
        ctx.pty_validity = value;
    }
}

pub fn setCurrentPty(value: ?u32) void {
    if (state) |*ctx| {
        ctx.mutex.lock();
        defer ctx.mutex.unlock();
        ctx.current_pty_id = value;
    }
}

pub fn record(comptime format: []const u8, args: anytype) void {
    if (state) |*ctx| {
        ctx.mutex.lock();
        defer ctx.mutex.unlock();

        var buf: [EVENT_BYTES_MAX]u8 = undefined;
        var stream = std.io.fixedBufferStream(&buf);
        const writer = stream.writer();
        writer.print("{d} ", .{std.time.milliTimestamp()}) catch return;
        writer.print(format, args) catch {};

        const written = stream.getWritten();
        const slot = ctx.next_event;
        ctx.events[slot].len = written.len;
        @memcpy(ctx.events[slot].bytes[0..written.len], written);

        ctx.next_event = (ctx.next_event + 1) % EVENT_CAPACITY;
        if (ctx.event_count < EVENT_CAPACITY) {
            ctx.event_count += 1;
        }
    }
}

pub fn writeBundle(
    reason: []const u8,
    session_json: ?[]const u8,
    trace: ?*const std.builtin.StackTrace,
) void {
    _ = writeBundleForTesting(std.heap.page_allocator, reason, session_json, trace) catch {};
}

pub fn writeBundleForTesting(
    allocator: std.mem.Allocator,
    reason: []const u8,
    session_json: ?[]const u8,
    trace: ?*const std.builtin.StackTrace,
) ![]u8 {
    var snapshot = try captureSnapshot(allocator, reason);
    defer snapshot.deinit(allocator);

    const cache_root = try buildCacheRoot(allocator, snapshot.cache_dir_override);
    defer allocator.free(cache_root);

    const crash_root = try std.fs.path.join(allocator, &.{ cache_root, "crash" });
    defer allocator.free(crash_root);
    try std.fs.cwd().makePath(crash_root);

    const bundle_name = try std.fmt.allocPrint(
        allocator,
        "{d}-{s}",
        .{ std.time.milliTimestamp(), roleName(snapshot.role) },
    );
    defer allocator.free(bundle_name);

    const bundle_path = try std.fs.path.join(allocator, &.{ crash_root, bundle_name });
    errdefer allocator.free(bundle_path);
    try std.fs.cwd().makePath(bundle_path);

    try writeSummary(allocator, bundle_path, &snapshot);
    try writeTextFile(allocator, bundle_path, "events.log", snapshot.events);
    try writeTailLog(allocator, cache_root, bundle_path, "client.log");
    try writeTailLog(allocator, cache_root, bundle_path, "server.log");
    try writeSessionSnapshot(allocator, bundle_path, session_json);
    try writeStackTrace(allocator, bundle_path, trace);
    return bundle_path;
}

fn setOwnedField(comptime field: std.meta.FieldEnum(State), value: []const u8) void {
    if (state) |*ctx| {
        ctx.mutex.lock();
        defer ctx.mutex.unlock();

        const duped = std.heap.page_allocator.dupe(u8, value) catch return;
        if (@field(ctx, @tagName(field))) |old| {
            std.heap.page_allocator.free(old);
        }
        @field(ctx, @tagName(field)) = duped;
    }
}

fn clearOwnedField(comptime field: std.meta.FieldEnum(State)) void {
    if (state) |*ctx| {
        ctx.mutex.lock();
        defer ctx.mutex.unlock();

        if (@field(ctx, @tagName(field))) |old| {
            std.heap.page_allocator.free(old);
        }
        @field(ctx, @tagName(field)) = null;
    }
}

fn captureSnapshot(allocator: std.mem.Allocator, reason: []const u8) !Snapshot {
    const ctx = if (state) |*value| value else return error.NotInitialized;

    if (!ctx.mutex.tryLock()) {
        return captureContendedSnapshot(allocator, ctx, reason);
    }
    defer ctx.mutex.unlock();

    return captureLockedSnapshot(allocator, ctx, reason);
}

fn captureLockedSnapshot(
    allocator: std.mem.Allocator,
    ctx: *const State,
    reason: []const u8,
) !Snapshot {
    const owned_reason = try allocator.dupe(u8, reason);
    errdefer allocator.free(owned_reason);

    const socket_path = try dupOptional(allocator, ctx.socket_path);
    errdefer if (socket_path) |value| allocator.free(value);

    const session_name = try dupOptional(allocator, ctx.session_name);
    errdefer if (session_name) |value| allocator.free(value);

    const cache_dir_override = try dupOptional(allocator, ctx.cache_dir_override);
    errdefer if (cache_dir_override) |value| allocator.free(value);

    const events = try collectEvents(allocator, ctx);
    errdefer allocator.free(events);

    return .{
        .role = ctx.role,
        .version = ctx.version,
        .reason = owned_reason,
        .snapshot_note = null,
        .socket_path = socket_path,
        .session_name = session_name,
        .cache_dir_override = cache_dir_override,
        .pty_validity = ctx.pty_validity,
        .current_pty_id = ctx.current_pty_id,
        .events = events,
    };
}

fn captureContendedSnapshot(
    allocator: std.mem.Allocator,
    ctx: *const State,
    reason: []const u8,
) !Snapshot {
    const owned_reason = try allocator.dupe(u8, reason);
    errdefer allocator.free(owned_reason);

    const snapshot_note = try allocator.dupe(u8, LOCK_CONTENTION_NOTE);
    errdefer allocator.free(snapshot_note);

    const events = try allocator.dupe(u8, LOCK_CONTENTION_NOTE ++ "\n");
    errdefer allocator.free(events);

    return .{
        .role = ctx.role,
        .version = ctx.version,
        .reason = owned_reason,
        .snapshot_note = snapshot_note,
        .socket_path = null,
        .session_name = null,
        .cache_dir_override = null,
        .pty_validity = null,
        .current_pty_id = null,
        .events = events,
    };
}

fn dupOptional(allocator: std.mem.Allocator, value: ?[]u8) !?[]u8 {
    if (value) |slice| {
        return try allocator.dupe(u8, slice);
    }
    return null;
}

fn collectEvents(allocator: std.mem.Allocator, ctx: *const State) ![]u8 {
    var list: std.ArrayList(u8) = .empty;
    errdefer list.deinit(allocator);

    const start = if (ctx.event_count == EVENT_CAPACITY) ctx.next_event else 0;
    var index: usize = 0;
    while (index < ctx.event_count) : (index += 1) {
        const slot = (start + index) % EVENT_CAPACITY;
        try list.appendSlice(allocator, ctx.events[slot].bytes[0..ctx.events[slot].len]);
        try list.append(allocator, '\n');
    }

    return list.toOwnedSlice(allocator);
}

fn buildCacheRoot(allocator: std.mem.Allocator, override_path: ?[]const u8) ![]u8 {
    if (override_path) |path| {
        return allocator.dupe(u8, path);
    }

    const home = std.posix.getenv("HOME") orelse return error.NoHomeDirectory;
    return std.fs.path.join(allocator, &.{ home, ".cache", "prise" });
}

fn writeSummary(
    allocator: std.mem.Allocator,
    bundle_path: []const u8,
    snapshot: *const Snapshot,
) !void {
    const summary = .{
        .version = snapshot.version,
        .role = roleName(snapshot.role),
        .reason = snapshot.reason,
        .snapshot_note = snapshot.snapshot_note,
        .socket_path = snapshot.socket_path,
        .session_name = snapshot.session_name,
        .pty_validity = snapshot.pty_validity,
        .current_pty_id = snapshot.current_pty_id,
    };

    const path = try std.fs.path.join(allocator, &.{ bundle_path, "summary.json" });
    defer allocator.free(path);

    const file = try std.fs.createFileAbsolute(path, .{});
    defer file.close();

    var buf: [4096]u8 = undefined;
    var writer = file.writer(&buf);
    defer writer.interface.flush() catch {};
    try std.json.Stringify.value(summary, .{}, &writer.interface);
}

fn writeTextFile(
    allocator: std.mem.Allocator,
    bundle_path: []const u8,
    file_name: []const u8,
    contents: []const u8,
) !void {
    const path = try std.fs.path.join(allocator, &.{ bundle_path, file_name });
    defer allocator.free(path);

    const file = try std.fs.createFileAbsolute(path, .{});
    defer file.close();
    try file.writeAll(contents);
}

fn writeTailLog(
    allocator: std.mem.Allocator,
    cache_root: []const u8,
    bundle_path: []const u8,
    file_name: []const u8,
) !void {
    const source_path = try std.fs.path.join(allocator, &.{ cache_root, file_name });
    defer allocator.free(source_path);

    const tail = try readTail(allocator, source_path) orelse return;
    defer allocator.free(tail);

    try writeTextFile(allocator, bundle_path, file_name, tail);
}

fn readTail(allocator: std.mem.Allocator, path: []const u8) !?[]u8 {
    const file = std.fs.openFileAbsolute(path, .{}) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };
    defer file.close();

    const end_pos = try file.getEndPos();
    const start_pos = if (end_pos > LOG_TAIL_BYTES_MAX) end_pos - LOG_TAIL_BYTES_MAX else 0;
    try file.seekTo(start_pos);
    const tail = try file.readToEndAlloc(allocator, LOG_TAIL_BYTES_MAX);
    return tail;
}

fn writeSessionSnapshot(
    allocator: std.mem.Allocator,
    bundle_path: []const u8,
    session_json: ?[]const u8,
) !void {
    const json = session_json orelse return;
    try writeTextFile(allocator, bundle_path, "session.json", json);
}

/// Writes a `trace.txt` file inside the crash bundle containing the raw
/// instruction addresses captured by `std.debug.captureStackTrace`. The
/// binary path is emitted as a header so the trace can be symbolicated later
/// with:
///
///     llvm-addr2line -e <binary-from-header> <addr>
///
/// Addresses are raw — symbolicating them requires the matching binary, so
/// keep the built binary alongside bundles you intend to investigate.
///
/// Skips file creation entirely when there is no trace to write — a null
/// pointer (panic fired without a first-trace address) or an empty trace
/// (`index == 0`, which covers targets where `sys_can_stack_trace == false`).
fn writeStackTrace(
    allocator: std.mem.Allocator,
    bundle_path: []const u8,
    trace: ?*const std.builtin.StackTrace,
) !void {
    const st = trace orelse return;
    if (st.index == 0) return;

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);

    try buf.appendSlice(allocator, "module=prise\n");

    // selfExePathAlloc may fail in exotic environments (sandboxed tests, etc.)
    // — degrade gracefully rather than dropping the whole trace.
    const exe_path = std.fs.selfExePathAlloc(allocator) catch null;
    defer if (exe_path) |path| allocator.free(path);
    if (exe_path) |path| {
        try buf.appendSlice(allocator, "binary=");
        try buf.appendSlice(allocator, path);
        try buf.append(allocator, '\n');
    } else {
        try buf.appendSlice(allocator, "binary=unknown\n");
    }

    // Slice by `index` — captureStackTrace may capture fewer frames than the
    // caller's buffer size, and the trailing slots are uninitialized.
    const frames = st.instruction_addresses[0..st.index];
    for (frames) |addr| {
        const line = try std.fmt.allocPrint(allocator, "addr=0x{x}\n", .{addr});
        defer allocator.free(line);
        try buf.appendSlice(allocator, line);
    }

    try writeTextFile(allocator, bundle_path, "trace.txt", buf.items);
}

fn roleName(role: Role) []const u8 {
    return switch (role) {
        .client => "client",
        .server => "server",
    };
}

const testing = std.testing;

const TestCacheDir = struct {
    tmp: testing.TmpDir,
    cache_root: []const u8,

    fn init(allocator: std.mem.Allocator) !TestCacheDir {
        var tmp = testing.tmpDir(.{});
        const cache_root = try tmp.parent_dir.realpathAlloc(allocator, &tmp.sub_path);
        errdefer allocator.free(cache_root);
        return .{
            .tmp = tmp,
            .cache_root = cache_root,
        };
    }

    fn deinit(self: *TestCacheDir, allocator: std.mem.Allocator) void {
        allocator.free(self.cache_root);
        self.tmp.cleanup();
    }
};

fn readFileAlloc(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    const file = try std.fs.openFileAbsolute(path, .{});
    defer file.close();
    return file.readToEndAlloc(allocator, 1024 * 1024);
}

test "writeBundleForTesting wraps events and writes bundle files" {
    var cache_dir = try TestCacheDir.init(testing.allocator);
    defer cache_dir.deinit(testing.allocator);
    defer deinit();

    init(.client, "test-version");
    setCacheDirOverrideForTests(cache_dir.cache_root);
    setSocketPath("/tmp/test.sock");
    setSessionName("session-a");
    setPtyValidity(1234);
    setCurrentPty(42);

    try writeTextFile(testing.allocator, cache_dir.cache_root, "client.log", "client tail");
    try writeTextFile(testing.allocator, cache_dir.cache_root, "server.log", "server tail");

    var index: usize = 0;
    while (index < EVENT_CAPACITY + 2) : (index += 1) {
        record("event {}", .{index});
    }

    const bundle_path = try writeBundleForTesting(testing.allocator, "boom", "{\"tabs\":[]}", null);
    defer testing.allocator.free(bundle_path);

    const events_path = try std.fs.path.join(testing.allocator, &.{ bundle_path, "events.log" });
    defer testing.allocator.free(events_path);
    const events = try readFileAlloc(testing.allocator, events_path);
    defer testing.allocator.free(events);
    try testing.expect(std.mem.indexOf(u8, events, "event 0") == null);
    try testing.expect(std.mem.indexOf(u8, events, "event 129") != null);

    const session_path = try std.fs.path.join(testing.allocator, &.{ bundle_path, "session.json" });
    defer testing.allocator.free(session_path);
    const session_json = try readFileAlloc(testing.allocator, session_path);
    defer testing.allocator.free(session_json);
    try testing.expectEqualStrings("{\"tabs\":[]}", session_json);
}

test "summary includes captured metadata" {
    var cache_dir = try TestCacheDir.init(testing.allocator);
    defer cache_dir.deinit(testing.allocator);
    defer deinit();

    init(.server, "v-test");
    setCacheDirOverrideForTests(cache_dir.cache_root);
    setSocketPath("/tmp/prise.sock");
    setSessionName("demo");
    setPtyValidity(99);
    setCurrentPty(7);

    const bundle_path = try writeBundleForTesting(testing.allocator, "server-failure", null, null);
    defer testing.allocator.free(bundle_path);

    const summary_path = try std.fs.path.join(testing.allocator, &.{ bundle_path, "summary.json" });
    defer testing.allocator.free(summary_path);
    const summary = try readFileAlloc(testing.allocator, summary_path);
    defer testing.allocator.free(summary);

    try testing.expect(std.mem.indexOf(u8, summary, "\"role\":\"server\"") != null);
    try testing.expect(std.mem.indexOf(u8, summary, "\"reason\":\"server-failure\"") != null);
    try testing.expect(std.mem.indexOf(u8, summary, "\"socket_path\":\"/tmp/prise.sock\"") != null);
    try testing.expect(std.mem.indexOf(u8, summary, "\"session_name\":\"demo\"") != null);
    try testing.expect(std.mem.indexOf(u8, summary, "\"pty_validity\":99") != null);
    try testing.expect(std.mem.indexOf(u8, summary, "\"current_pty_id\":7") != null);
    try testing.expect(std.mem.indexOf(u8, summary, "\"snapshot_note\":null") != null);
}

test "writeBundleForTesting degrades on crash context lock contention" {
    defer deinit();

    init(.client, "lock-test");
    setSocketPath("/tmp/prise.sock");
    setSessionName("demo");
    setPtyValidity(77);
    setCurrentPty(5);
    record("event {}", .{1});

    state.?.mutex.lock();
    const bundle_path = try writeBundleForTesting(testing.allocator, "panic-path", null, null);
    state.?.mutex.unlock();
    defer testing.allocator.free(bundle_path);
    defer std.fs.deleteTreeAbsolute(bundle_path) catch {};

    const summary_path = try std.fs.path.join(testing.allocator, &.{ bundle_path, "summary.json" });
    defer testing.allocator.free(summary_path);
    const summary = try readFileAlloc(testing.allocator, summary_path);
    defer testing.allocator.free(summary);

    try testing.expect(std.mem.indexOf(u8, summary, "\"reason\":\"panic-path\"") != null);
    try testing.expect(std.mem.indexOf(u8, summary, "\"snapshot_note\":\"" ++ LOCK_CONTENTION_NOTE ++ "\"") != null);
    try testing.expect(std.mem.indexOf(u8, summary, "\"socket_path\":null") != null);
    try testing.expect(std.mem.indexOf(u8, summary, "\"session_name\":null") != null);
    try testing.expect(std.mem.indexOf(u8, summary, "\"pty_validity\":null") != null);
    try testing.expect(std.mem.indexOf(u8, summary, "\"current_pty_id\":null") != null);

    const events_path = try std.fs.path.join(testing.allocator, &.{ bundle_path, "events.log" });
    defer testing.allocator.free(events_path);
    const events = try readFileAlloc(testing.allocator, events_path);
    defer testing.allocator.free(events);

    try testing.expectEqualStrings(LOCK_CONTENTION_NOTE ++ "\n", events);
}

test "writeBundleForTesting emits trace.txt when a stack trace is passed" {
    var cache_dir = try TestCacheDir.init(testing.allocator);
    defer cache_dir.deinit(testing.allocator);
    defer deinit();

    init(.client, "trace-test");
    setCacheDirOverrideForTests(cache_dir.cache_root);

    // Synthesize a short trace with three known addresses — we just want to
    // prove writeStackTrace emits each one in the expected `addr=0x<hex>`
    // form, not to validate captureStackTrace itself.
    var addrs: [4]usize = .{ 0xdeadbeef, 0xcafebabe, 0xfeedface, 0 };
    const trace: std.builtin.StackTrace = .{
        .instruction_addresses = &addrs,
        .index = 3,
    };

    const bundle_path = try writeBundleForTesting(testing.allocator, "trace-check", null, &trace);
    defer testing.allocator.free(bundle_path);

    const trace_path = try std.fs.path.join(testing.allocator, &.{ bundle_path, "trace.txt" });
    defer testing.allocator.free(trace_path);
    const contents = try readFileAlloc(testing.allocator, trace_path);
    defer testing.allocator.free(contents);

    try testing.expect(std.mem.indexOf(u8, contents, "module=prise") != null);
    try testing.expect(std.mem.indexOf(u8, contents, "binary=") != null);
    try testing.expect(std.mem.indexOf(u8, contents, "addr=0xdeadbeef") != null);
    try testing.expect(std.mem.indexOf(u8, contents, "addr=0xcafebabe") != null);
    try testing.expect(std.mem.indexOf(u8, contents, "addr=0xfeedface") != null);

    // The trailing zero slot (index == 3, buffer length 4) must be excluded.
    try testing.expect(std.mem.indexOf(u8, contents, "addr=0x0\n") == null);
}

test "writeBundleForTesting skips trace.txt when trace is null or empty" {
    var cache_dir = try TestCacheDir.init(testing.allocator);
    defer cache_dir.deinit(testing.allocator);
    defer deinit();

    init(.client, "trace-skip-test");
    setCacheDirOverrideForTests(cache_dir.cache_root);

    // Null trace — no file.
    const null_bundle = try writeBundleForTesting(testing.allocator, "no-trace", null, null);
    defer testing.allocator.free(null_bundle);
    const null_trace_path = try std.fs.path.join(testing.allocator, &.{ null_bundle, "trace.txt" });
    defer testing.allocator.free(null_trace_path);
    try testing.expectError(error.FileNotFound, std.fs.openFileAbsolute(null_trace_path, .{}));

    // Empty trace (index == 0) — also no file. Covers targets where
    // sys_can_stack_trace is false and captureStackTrace is a no-op.
    var addrs: [4]usize = undefined;
    const empty_trace: std.builtin.StackTrace = .{
        .instruction_addresses = &addrs,
        .index = 0,
    };
    const empty_bundle = try writeBundleForTesting(testing.allocator, "empty-trace", null, &empty_trace);
    defer testing.allocator.free(empty_bundle);
    const empty_trace_path = try std.fs.path.join(testing.allocator, &.{ empty_bundle, "trace.txt" });
    defer testing.allocator.free(empty_trace_path);
    try testing.expectError(error.FileNotFound, std.fs.openFileAbsolute(empty_trace_path, .{}));
}
