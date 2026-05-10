//! Server that manages PTYs and client connections.

const std = @import("std");
const builtin = @import("builtin");
const crash_context = @import("crash_context.zig");

const ghostty_vt = @import("ghostty-vt");

const io = @import("io.zig");
const key_encode = @import("key_encode.zig");
const key_parse = @import("key_parse.zig");
const main = @import("main.zig");
const mouse_encode = @import("mouse_encode.zig");
const msgpack = @import("msgpack.zig");
const plug_config = @import("plug_config.zig");
const pty = @import("pty.zig");
const redraw = @import("redraw.zig");
const rpc = @import("rpc.zig");
const vt_handler = @import("vt_handler.zig");

const csig = @cImport({
    @cInclude("signal.h");
    @cInclude("unistd.h");
});

const posix = std.posix;

const log = std.log.scoped(.server);

fn logPtyWriteError(err: anyerror) void {
    if (err != error.WouldBlock) {
        logPtyWriteError(err);
    }
}

/// Resource limits to prevent unbounded growth in the long-running daemon.
pub const LIMITS = struct {
    pub const CLIENTS_MAX: usize = 64;
    pub const PTYS_MAX: usize = 256;
    pub const MESSAGE_SIZE_MAX: usize = 16 * 1024 * 1024; // 16MB
    pub const SEND_QUEUE_MAX: usize = 1024;
    pub const TITLE_LEN_MAX: usize = 4096;
    pub const CWD_LEN_MAX: usize = 4096; // typical PATH_MAX
    pub const COLOR_QUERY_MAX: usize = 32;
    pub const RESPONSE_QUEUE_MAX: usize = 64;
    pub const COLOR_QUERY_TIMEOUT_MS: i64 = 5000;
    /// Defensive ceiling on in-flight client-broker RPC requests
    /// (e.g. break_pane). Single-user case will never approach 64; the
    /// limit guards against runaway state from a misbehaving caller.
    pub const PENDING_MAX: usize = 64;
    /// Default deadline for a pending broker-RPC: well above local UDS
    /// RTT, well below "is it broken" user threshold. Sweep timer fires
    /// `broker_timeout` to the originating CLI when exceeded.
    pub const PENDING_DEADLINE_MS: i64 = 2000;
    /// Cadence for the deadline-sweep timer that retires expired
    /// pending entries. Bounded delay between deadline-exceeded and
    /// timeout reply.
    pub const PENDING_SWEEP_MS: u64 = 250;
    // Upper bound on argv entries accepted by spawn_pty's direct-exec path.
    // Plenty of room for realistic program invocations without unbounded
    // stack buffers.
    pub const SPAWN_ARGV_MAX: usize = 64;
    pub const PLUG_NAME_MAX: usize = 64;
    pub const CALL_FORWARD_TIMEOUT_MS: i64 = 30_000;
    pub const PENDING_FORWARDS_MAX: usize = 256;
    pub const PLUG_TOKEN_BYTES: usize = 16;
    pub const PLUG_TOKEN_HEX_LEN: usize = PLUG_TOKEN_BYTES * 2;
    /// Grace window for a managed plug to honor SIGTERM during server
    /// shutdown before we escalate to SIGKILL. Bounded so the server
    /// itself cannot block indefinitely on a wedged plug.
    pub const PLUG_SHUTDOWN_GRACE_MS: u64 = 1500;
};

/// Who initiated this managed plug. Drives the spawn_plug RPC collision check:
/// a `.config` plug is server-owned (declared in prise.toml) and may not be
/// reconfigured at runtime; a `.rpc` plug is client-owned (declared via the
/// spawn_plug RPC) and keeps existing dedup semantics.
pub const PlugOwner = enum { config, rpc };

/// A plug process spawned and managed by the server.
const ManagedPlug = struct {
    name: []const u8,
    cmd: []const []const u8,
    restart: bool,
    restart_delay_ms: u32,
    /// Default `.rpc` so the existing RPC path keeps current semantics with
    /// no callsite churn. The TOML-driven loader explicitly sets `.config`.
    owner: PlugOwner = .rpc,
    token: [LIMITS.PLUG_TOKEN_HEX_LEN]u8 = undefined,
    pid: ?posix.pid_t = null,
    registered: bool = false,
    restart_count: u32 = 0,
    /// Set when the process has been killed by the server (shutdown or replacement).
    killed_by_server: bool = false,
    /// Tracks the pending waitpid task so it can be cancelled on shutdown.
    waitpid_task: ?io.Task = null,
    /// Pending restart timer — stored so shutdown can cancel it.
    restart_timer_task: ?io.Task = null,
    /// Heap-allocated restart context — freed on cancel or when timer fires.
    restart_ctx: ?*RestartContext = null,

    fn deinit(self: *ManagedPlug, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        for (self.cmd) |arg| allocator.free(arg);
        allocator.free(self.cmd);
    }
};

/// Heap context for a pending restart timer. Owns a duped plug name
/// so the callback is safe even if the ManagedPlug is freed first.
const RestartContext = struct {
    server: *Server,
    plug_name: []const u8,
};

/// A call_plug request in flight, waiting for the plug's response.
const PendingForward = struct {
    /// The TUI client that initiated the call.
    originator: *Client,
    /// The original msgid from the TUI client's request.
    orig_msgid: u32,
    /// Timestamp when this forward was created, for timeout detection.
    created_ms: i64,
    /// Name of the target plug (for error messages on timeout).
    /// OWNED — must be freed on removal from pending_forwards.
    plug_name: []const u8,
};

/// Heap context for the forward-timeout sweep timer.
const SweepTimerContext = struct {
    server: *Server,
};

/// In-flight client-broker RPC request awaiting a reply notification
/// from the chosen broker client. Currently used only by `break_pane`,
/// but the shape is method-agnostic — extend with method-specific
/// fields as more brokered RPCs land.
const PendingBreak = struct {
    /// msgid of the original CLI request — needed to build the
    /// matching Response to the originator when the broker replies
    /// (or when the deadline sweep / removeClient retires the entry).
    cli_msgid: u32,
    /// The CLI client awaiting the reply. We may need to send a
    /// Response (success/failure) to this client.
    cli_client: *Client,
    /// `Client.id` of the chosen broker. Used for matching against
    /// `removeClient` (broker disconnected → reply `broker_timeout`).
    broker_id: usize,
    /// Wall-clock deadline (ms since epoch). Sweep timer compares
    /// against `std.time.milliTimestamp()`.
    deadline_ts: i64,
    /// Pty id from the original request — replayed in the
    /// `break_pane_applied` broadcast on success.
    pty_id: u32,
    /// Focus flag from the original request — replayed in the
    /// `break_pane_applied` broadcast on success.
    focus: bool,
};

var signal_write_fd: posix.fd_t = undefined;

fn signalHandler(sig: c_int) callconv(std.builtin.CallingConvention.c) void {
    // Ignore further signals
    const ignore: posix.Sigaction = .{
        .handler = .{ .handler = posix.SIG.IGN },
        .mask = posix.sigemptyset(),
        .flags = 0,
    };
    posix.sigaction(posix.SIG.INT, &ignore, null);
    posix.sigaction(posix.SIG.TERM, &ignore, null);

    _ = sig;
    _ = posix.write(signal_write_fd, "s") catch {};
}

/// Writes all data to the file descriptor, looping on partial writes.
/// Handles WouldBlock by retrying with a short sleep.
fn writeAllFd(fd: posix.fd_t, data: []const u8) !void {
    var index: usize = 0;
    while (index < data.len) {
        const n = posix.write(fd, data[index..]) catch |err| {
            if (err == error.WouldBlock) {
                std.Thread.sleep(1 * std.time.ns_per_ms);
                continue;
            }
            return err;
        };
        index += n;
    }
}

const Pty = struct {
    // Type declarations must come before fields
    const ColorQuery = struct {
        target: vt_handler.ColorTarget,
        timestamp_ms: i64,
        response_slot: usize, // Index into response_queue for this query's response
    };

    const QueuedResponse = struct {
        const Tag = enum { pending_color, ready };
        tag: Tag,
        data: [64]u8 = undefined,
        len: usize = 0,

        fn ready(response: []const u8) QueuedResponse {
            var r: QueuedResponse = .{ .tag = .ready, .len = @min(response.len, 64) };
            @memcpy(r.data[0..r.len], response[0..r.len]);
            return r;
        }

        fn pendingColor() QueuedResponse {
            return .{ .tag = .pending_color };
        }
    };

    id: usize,
    process: pty.Process,
    clients: std.ArrayList(*Client),
    read_thread: ?std.Thread = null,
    running: std.atomic.Value(bool),
    terminal: ghostty_vt.Terminal,
    allocator: std.mem.Allocator,

    // Title of the terminal window
    title: std.ArrayList(u8),
    title_dirty: bool = false,

    // Current working directory (from OSC 7)
    cwd: std.ArrayList(u8),
    cwd_dirty: bool = false,

    // Pending color query requests from PTY applications
    color_queries_buf: [LIMITS.COLOR_QUERY_MAX]ColorQuery = undefined,
    color_queries_len: usize = 0,
    color_queries_mutex: std.Thread.Mutex = .{},

    // Response queue for ordered response delivery (ring buffer with absolute slots)
    response_queue: [LIMITS.RESPONSE_QUEUE_MAX]QueuedResponse = undefined,
    response_queue_head: usize = 0, // Next slot to flush (absolute, wraps)
    response_queue_tail: usize = 0, // Next slot to allocate (absolute, wraps)
    response_queue_start: i64 = 0, // Timestamp when first item was queued

    // Track color queries sent vs responses received
    color_queries_sent: usize = 0,
    color_queries_received: usize = 0,

    // Pending DA1 response - held until color queries are resolved or timeout
    da1_pending: bool = false,
    da1_timestamp_ms: i64 = 0,

    // Exit state
    exited: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    exit_status: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),

    // Synchronization for terminal access
    terminal_mutex: std.Thread.Mutex = .{},

    // Dirty signaling
    pipe_fds: [2]posix.fd_t,
    exit_pipe_fds: [2]posix.fd_t,
    dirty_signal_buf: [1]u8 = undefined,
    last_render_time: i64 = 0,
    render_timer: ?io.Task = null,
    render_state: ghostty_vt.RenderState,

    // Selection state: stores click position for drag selection as a Pin
    // to survive viewport scrolling during drag operations
    selection_start: ?ghostty_vt.PageList.Pin = null,
    // Click counting for double/triple click
    left_click_count: u8 = 0,
    left_click_time: i64 = 0, // milliseconds timestamp

    // Pointer to server for callbacks (opaque to avoid circular type dependency)
    server_ptr: *anyopaque = undefined,

    // The client whose dimensions control the PTY size.
    // Only resize requests from this client are applied; others are ignored.
    // Updated on attach (newest client becomes owner) and detach (falls back
    // to first remaining client).
    size_owner: ?*Client = null,

    fn init(allocator: std.mem.Allocator, id: usize, process_instance: pty.Process, size: pty.Winsize) !*Pty {
        // Precondition: terminal size must be positive (zero would crash ghostty-vt)
        std.debug.assert(size.ws_col > 0);
        std.debug.assert(size.ws_row > 0);
        // Precondition: process must have valid master fd
        std.debug.assert(process_instance.master >= 0);

        const instance = try allocator.create(Pty);
        errdefer allocator.destroy(instance);

        const pipe_fds = try posix.pipe2(.{ .NONBLOCK = true, .CLOEXEC = true });
        errdefer {
            posix.close(pipe_fds[0]);
            posix.close(pipe_fds[1]);
        }

        const exit_pipe_fds = try posix.pipe2(.{ .NONBLOCK = true, .CLOEXEC = true });
        errdefer {
            posix.close(exit_pipe_fds[0]);
            posix.close(exit_pipe_fds[1]);
        }

        instance.* = .{
            .id = id,
            .process = process_instance,
            .clients = std.ArrayList(*Client).empty,
            .running = std.atomic.Value(bool).init(true),
            .terminal = try ghostty_vt.Terminal.init(allocator, .{
                .cols = size.ws_col,
                .rows = size.ws_row,
            }),
            .allocator = allocator,
            .title = std.ArrayList(u8).empty,
            .title_dirty = false,
            .cwd = std.ArrayList(u8).empty,
            .cwd_dirty = false,
            .pipe_fds = pipe_fds,
            .exit_pipe_fds = exit_pipe_fds,
            .render_state = .empty,
        };

        // Postcondition: instance initialized in running state with no clients
        std.debug.assert(instance.running.load(.seq_cst) == true);
        std.debug.assert(instance.clients.items.len == 0);

        return instance;
    }

    /// Cancel pending IO operations.
    fn cancelPendingIO(self: *Pty, loop: *io.Loop) void {
        // Cancel any pending render timer
        if (self.render_timer) |*task| {
            task.cancel(loop) catch {};
            self.render_timer = null;
        }

        // Cancel pending read on dirty signal pipe
        loop.cancelByFd(self.pipe_fds[0]);
    }

    /// Join read thread and free resources (call after event loop exits)
    fn joinAndFree(self: *Pty, allocator: std.mem.Allocator) void {
        // Precondition: all clients must be detached before freeing
        std.debug.assert(self.clients.items.len == 0);
        // Precondition: running flag must be false (stopAndCancelIO was called)
        std.debug.assert(!self.running.load(.seq_cst));

        if (self.read_thread) |thread| {
            thread.join();
        }

        // If the process is still running (thread was killed before it could reap),
        // ensure we terminate it with SIGKILL before cleanup
        if (!self.exited.load(.acquire)) {
            _ = posix.kill(self.process.pid, posix.SIG.KILL) catch {};
            // Give it a moment to die
            std.Thread.sleep(10 * std.time.ns_per_ms);
        }

        self.process.close();

        posix.close(self.pipe_fds[0]);
        posix.close(self.pipe_fds[1]);
        posix.close(self.exit_pipe_fds[0]);
        posix.close(self.exit_pipe_fds[1]);
        self.terminal.deinit(allocator);
        self.render_state.deinit(allocator);
        self.clients.deinit(allocator);
        self.title.deinit(allocator);
        self.cwd.deinit(allocator);
        allocator.destroy(self);
    }

    fn deinit(self: *Pty, allocator: std.mem.Allocator, loop: *io.Loop) void {
        // Precondition: all clients must be detached before deinit
        std.debug.assert(self.clients.items.len == 0);

        self.stopAndCancelIO(loop);
        self.joinAndFree(allocator);
    }

    /// Attach a client to this PTY. Returns true if the client was newly
    /// added; false if the client was already attached (idempotent no-op).
    /// Idempotency is load-bearing: a corrupt session file listing the same
    /// pty_id in multiple tabs round-trips as duplicate attach_pty RPCs, and
    /// returning an error here would land in the client's restore-failure
    /// rollback rather than the success path. Tolerating the duplicate keeps
    /// the server alive and the restore intact.
    fn addClient(self: *Pty, allocator: std.mem.Allocator, client: *Client) !bool {
        // Precondition: PTY must be running to accept new clients
        std.debug.assert(self.running.load(.seq_cst));

        for (self.clients.items) |c| {
            if (c == client) {
                log.warn("addClient: client fd={} already attached to PTY (no-op)", .{client.fd});
                return false;
            }
        }
        // Precondition: must not exceed client limit
        std.debug.assert(self.clients.items.len < LIMITS.CLIENTS_MAX);

        const prev_len = self.clients.items.len;
        try self.clients.append(allocator, client);

        // Most recently attached client becomes size owner
        self.size_owner = client;

        // Postcondition: client count increased by exactly one
        std.debug.assert(self.clients.items.len == prev_len + 1);
        return true;
    }

    fn isClientAttached(self: *const Pty, client: *const Client) bool {
        for (self.clients.items) |c| {
            if (c == client) return true;
        }
        return false;
    }

    fn removeClient(self: *Pty, client: *Client) void {
        for (self.clients.items, 0..) |c, i| {
            if (c == client) {
                _ = self.clients.swapRemove(i);

                // If the removed client was size owner, transfer to first remaining
                if (self.size_owner == client) {
                    self.size_owner = if (self.clients.items.len > 0) self.clients.items[0] else null;
                }
                return;
            }
        }
        // Client not found - already removed (e.g., via detach_pty)
    }

    fn setTitle(self: *Pty, title: []const u8) !void {
        // Mutex is already held by readThread when this is called via callback

        // Truncate title to prevent unbounded growth
        const truncated = if (title.len > LIMITS.TITLE_LEN_MAX) title[0..LIMITS.TITLE_LEN_MAX] else title;

        // Update internal title
        self.title.clearRetainingCapacity();
        try self.title.appendSlice(self.allocator, truncated);
        self.title_dirty = true;
    }

    fn setCwd(self: *Pty, cwd: []const u8) !void {
        // Mutex is already held by readThread when this is called via callback
        const truncated = if (cwd.len > LIMITS.CWD_LEN_MAX) cwd[0..LIMITS.CWD_LEN_MAX] else cwd;

        self.cwd.clearRetainingCapacity();
        try self.cwd.appendSlice(self.allocator, truncated);
        self.cwd_dirty = true;
    }

    fn queueColorQuery(self: *Pty, target: vt_handler.ColorTarget) void {
        self.color_queries_mutex.lock();
        defer self.color_queries_mutex.unlock();

        const now_ms = std.time.milliTimestamp();

        // Check response queue capacity first
        const queue_len = self.response_queue_tail - self.response_queue_head;
        if (queue_len >= LIMITS.RESPONSE_QUEUE_MAX) {
            log.warn("Response queue full, dropping color query", .{});
            return;
        }

        if (self.color_queries_len >= LIMITS.COLOR_QUERY_MAX) {
            log.warn("Color query queue full, dropping query", .{});
            return;
        }

        // Allocate a slot in the response queue for this color query (absolute slot)
        const slot = self.response_queue_tail;
        self.response_queue[slot % LIMITS.RESPONSE_QUEUE_MAX] = QueuedResponse.pendingColor();
        self.response_queue_tail += 1;
        if (queue_len == 0) {
            self.response_queue_start = now_ms;
        }

        self.color_queries_buf[self.color_queries_len] = .{
            .target = target,
            .timestamp_ms = now_ms,
            .response_slot = slot,
        };
        self.color_queries_len += 1;

        // Signal dirty to trigger sending color queries to client
        _ = posix.write(self.pipe_fds[1], "c") catch {};
    }

    /// Queue a DA1 response to be sent after all other responses are flushed.
    fn queueDa1(self: *Pty) void {
        self.color_queries_mutex.lock();
        defer self.color_queries_mutex.unlock();

        self.da1_pending = true;
        self.da1_timestamp_ms = std.time.milliTimestamp();

        // Try to send immediately if queue is empty, otherwise signal dirty
        _ = self.flushResponsesUnlocked();
        _ = posix.write(self.pipe_fds[1], "d") catch {};
    }

    /// Queue a response to be sent to the PTY in order.
    fn queueResponse(self: *Pty, response: []const u8) void {
        self.color_queries_mutex.lock();
        defer self.color_queries_mutex.unlock();

        const queue_len = self.response_queue_tail - self.response_queue_head;
        if (queue_len >= LIMITS.RESPONSE_QUEUE_MAX) {
            log.warn("Response queue full, dropping response", .{});
            return;
        }

        self.response_queue[self.response_queue_tail % LIMITS.RESPONSE_QUEUE_MAX] = QueuedResponse.ready(response);
        self.response_queue_tail += 1;
        if (queue_len == 0) {
            self.response_queue_start = std.time.milliTimestamp();
        }
    }

    /// Fill in a color query response at its reserved slot.
    fn fillColorResponse(self: *Pty, slot: usize, response: []const u8) void {
        self.color_queries_mutex.lock();
        defer self.color_queries_mutex.unlock();

        // Slot must be within the current queue range (head <= slot < tail)
        if (slot >= self.response_queue_head and slot < self.response_queue_tail) {
            self.response_queue[slot % LIMITS.RESPONSE_QUEUE_MAX] = QueuedResponse.ready(response);
        }
    }

    /// Try to flush ready responses from the front of the queue.
    /// Returns true if there are still pending responses.
    fn flushResponses(self: *Pty) bool {
        self.color_queries_mutex.lock();
        defer self.color_queries_mutex.unlock();
        return self.flushResponsesUnlocked();
    }

    /// Flush responses without taking the lock (caller must hold color_queries_mutex).
    fn flushResponsesUnlocked(self: *Pty) bool {
        const now_ms = std.time.milliTimestamp();
        const queue_len = self.response_queue_tail - self.response_queue_head;
        const timed_out = queue_len > 0 and
            (now_ms - self.response_queue_start > LIMITS.COLOR_QUERY_TIMEOUT_MS);

        // Flush consecutive ready responses from the head
        while (self.response_queue_head < self.response_queue_tail) {
            const resp = &self.response_queue[self.response_queue_head % LIMITS.RESPONSE_QUEUE_MAX];
            if (resp.tag == .pending_color) {
                if (timed_out) {
                    // Skip timed-out pending responses
                    self.response_queue_head += 1;
                    continue;
                }
                break; // Wait for this response
            }
            // Write ready response to PTY
            writeAllFd(self.process.master, resp.data[0..resp.len]) catch |err| {
                log.err("Failed to write response to PTY: {}", .{err});
            };
            self.response_queue_head += 1;
        }

        // Update start time if queue still has items
        const new_queue_len = self.response_queue_tail - self.response_queue_head;
        if (new_queue_len > 0 and new_queue_len < queue_len) {
            self.response_queue_start = now_ms;
        }

        // Send DA1 if queue is empty and DA1 is pending
        if (self.da1_pending and new_queue_len == 0) {
            self.da1_pending = false;
            writeAllFd(self.process.master, "\x1b[?1;2c") catch |err| {
                log.err("Failed to write DA1 response to PTY: {}", .{err});
            };
        }

        return new_queue_len > 0;
    }

    // Removed broadcast - we'll send msgpack-RPC redraw notifications instead

    fn readThread(self: *Pty, server: *Server) void {
        _ = server;
        // Precondition: PTY must be in running state when thread starts
        std.debug.assert(self.running.load(.seq_cst));
        // Precondition: process master fd must be valid
        std.debug.assert(self.process.master >= 0);

        // 4096 bytes matches typical pipe buffer size and is large enough to
        // batch multiple VT sequences per read, reducing syscall overhead while
        // staying small enough for stack allocation.
        var buffer: [4096]u8 = undefined;

        var handler = vt_handler.Handler.init(&self.terminal);
        defer handler.deinit();

        // Set up the write callback so the handler can respond to queries.
        // Responses are queued to ensure proper ordering with async color responses.
        handler.setWriteCallback(self, struct {
            fn writeToPty(ctx: ?*anyopaque, data: []const u8) !void {
                const pty_inst: *Pty = @ptrCast(@alignCast(ctx));
                pty_inst.queueResponse(data);
                _ = pty_inst.flushResponses();
            }
        }.writeToPty);

        // Set up title callback
        handler.setTitleCallback(self, struct {
            fn onTitle(ctx: ?*anyopaque, title: []const u8) !void {
                const pty_inst: *Pty = @ptrCast(@alignCast(ctx));
                pty_inst.setTitle(title) catch |err| {
                    log.err("Failed to set title: {}", .{err});
                };
            }
        }.onTitle);

        // Set up cwd callback (OSC 7)
        handler.setCwdCallback(self, struct {
            fn onCwd(ctx: ?*anyopaque, cwd: []const u8) !void {
                const pty_inst: *Pty = @ptrCast(@alignCast(ctx));
                pty_inst.setCwd(cwd) catch |err| {
                    log.err("Failed to set cwd: {}", .{err});
                };
            }
        }.onCwd);

        // Set up color query callback (OSC 4/10/11/12)
        handler.setColorQueryCallback(self, struct {
            fn onColorQuery(ctx: ?*anyopaque, target: vt_handler.ColorTarget) !void {
                const pty_inst: *Pty = @ptrCast(@alignCast(ctx));
                pty_inst.queueColorQuery(target);
            }
        }.onColorQuery);

        // Set up DA1 callback - defer response until color queries are resolved
        handler.setDa1Callback(self, struct {
            fn onDa1(ctx: ?*anyopaque) !void {
                const pty_inst: *Pty = @ptrCast(@alignCast(ctx));
                pty_inst.queueDa1();
            }
        }.onDa1);

        var stream = vt_handler.Stream.initAlloc(self.allocator, handler);
        defer stream.deinit();

        var poll_fds = [_]posix.pollfd{
            .{ .fd = self.process.master, .events = posix.POLL.IN, .revents = 0 },
            .{ .fd = self.exit_pipe_fds[0], .events = posix.POLL.IN, .revents = 0 },
        };

        while (self.running.load(.seq_cst)) {
            // Tight loop: drain PTY buffer
            while (true) {
                const n = posix.read(self.process.master, &buffer) catch |err| {
                    if (err == error.WouldBlock) break; // Buffer empty, time to poll
                    log.err("PTY read error: {}", .{err});
                    self.running.store(false, .seq_cst);
                    break;
                };
                if (n == 0) {
                    log.info("PTY {} master returned EOF", .{self.id});
                    self.running.store(false, .seq_cst);
                    break;
                }

                // Lock mutex and update terminal state
                self.terminal_mutex.lock();
                // Parse the data through ghostty-vt to update terminal state
                stream.nextSlice(buffer[0..n]);
                // Check synchronized_output while still holding the mutex
                const should_signal = !self.terminal.modes.get(.synchronized_output);
                self.terminal_mutex.unlock();

                // Notify main thread by writing to pipe
                // Ignore EAGAIN (pipe full means already dirty)
                // Skip signaling during synchronized_output mode (DEC mode 2026) because
                // the application is in the middle of an atomic update. We'll render when
                // the mode is cleared, avoiding partial/flickering frames.
                if (should_signal) {
                    _ = posix.write(self.pipe_fds[1], "x") catch |err| {
                        if (err != error.WouldBlock) {
                            log.err("Failed to signal dirty: {}", .{err});
                        }
                    };
                }
            }

            if (!self.running.load(.seq_cst)) break;

            // Poll for more data or exit signal
            _ = posix.poll(&poll_fds, -1) catch |err| {
                log.err("Poll error: {}", .{err});
                break;
            };

            if (poll_fds[1].revents & posix.POLL.IN != 0) {
                break;
            }

            // Check for POLLHUP on master (process closed its side)
            if (poll_fds[0].revents & posix.POLL.HUP != 0) {
                self.running.store(false, .seq_cst);
                break;
            }
        }
        log.info("PTY read thread exiting for PTY {}", .{self.id});

        // Ghostty-style kill loop: repeatedly signal and poll until process exits
        const status = self.killAndReap();
        self.exit_status.store(status, .seq_cst);
        self.exited.store(true, .seq_cst);

        // Signal main thread that process has exited (reuse dirty pipe)
        _ = posix.write(self.pipe_fds[1], "e") catch {};
    }

    /// Kill the process group and reap the child. Returns exit status.
    /// Closes master fd first (triggers kernel SIGHUP), then escalates signals.
    fn killAndReap(self: *Pty) u32 {
        const pid = self.process.pid;

        // Close master fd first - this triggers kernel SIGHUP to the process group
        // when the slave side detects the hangup condition
        posix.close(self.process.master);
        self.process.master = -1;

        // Get the process group ID, waiting for setsid if needed
        const pgid = getpgid(pid) orelse {
            // Process doesn't exist, try to reap anyway
            const res = posix.waitpid(pid, posix.W.NOHANG);
            return res.status;
        };

        // Wait a bit for kernel-triggered SIGHUP to take effect
        for (0..10) |_| {
            const res = posix.waitpid(pid, posix.W.NOHANG);
            if (res.pid != 0) {
                log.info("PTY {} process exited with status {}", .{ self.id, res.status });
                return res.status;
            }
            std.Thread.sleep(10 * std.time.ns_per_ms);
        }

        // Signal escalation: SIGHUP -> SIGTERM -> SIGKILL
        const signals = [_]c_int{ csig.SIGHUP, csig.SIGTERM, csig.SIGKILL };
        const iterations_per_signal: usize = 10; // 10 * 10ms = 100ms per signal

        for (signals) |sig| {
            _ = csig.killpg(pgid, sig);

            for (0..iterations_per_signal) |_| {
                const res = posix.waitpid(pid, posix.W.NOHANG);
                if (res.pid != 0) {
                    log.info("PTY {} process exited with status {}", .{ self.id, res.status });
                    return res.status;
                }
                std.Thread.sleep(10 * std.time.ns_per_ms);
            }
        }

        // SIGKILL should always work, but keep trying
        log.warn("PTY {} process still alive after SIGKILL, polling", .{self.id});
        while (true) {
            const res = posix.waitpid(pid, posix.W.NOHANG);
            if (res.pid != 0) {
                log.info("PTY {} process exited with status {}", .{ self.id, res.status });
                return res.status;
            }
            std.Thread.sleep(10 * std.time.ns_per_ms);
        }
    }
};

/// Get the process group ID for a pid, waiting for setsid if needed.
/// Returns null if the process doesn't exist.
fn getpgid(pid: posix.pid_t) ?posix.pid_t {
    // Get our own process group ID
    const my_pgid = csig.getpgid(0);

    // Loop while pgid == my_pgid (setsid not yet called by child)
    while (true) {
        const pgid = csig.getpgid(pid);

        // If still in parent's group, setsid() hasn't completed yet
        if (pgid == my_pgid) {
            std.Thread.sleep(10 * std.time.ns_per_ms);
            continue;
        }

        // Invalid or error cases
        if (pgid == 0) return null;
        if (pgid < 0) return null;

        return pgid;
    }
}

/// Map ghostty MouseShape to redraw MouseShape
fn mapMouseShape(shape: ghostty_vt.MouseShape) redraw.UIEvent.MouseShape.Shape {
    return switch (shape) {
        .default => .default,
        .text => .text,
        .pointer => .pointer,
        .help => .help,
        .progress => .progress,
        .wait => .wait,
        .cell => .cell,
        .crosshair => .crosshair,
        .move => .move,
        .not_allowed => .not_allowed,
        .no_drop => .not_allowed,
        .grab => .grab,
        .grabbing => .grabbing,
        .ew_resize, .e_resize, .w_resize => .ew_resize,
        .ns_resize, .n_resize, .s_resize => .ns_resize,
        .nesw_resize, .ne_resize, .sw_resize => .nesw_resize,
        .nwse_resize, .nw_resize, .se_resize => .nwse_resize,
        .col_resize => .col_resize,
        .row_resize => .row_resize,
        .all_scroll => .all_scroll,
        .zoom_in => .zoom_in,
        .zoom_out => .zoom_out,
        .context_menu, .alias, .copy, .vertical_text => .default,
    };
}

/// Convert ghostty style to Prise Style Attributes
fn getStyleAttributes(style: ghostty_vt.Style) redraw.UIEvent.Style.Attributes {
    var attrs: redraw.UIEvent.Style.Attributes = .{};

    // Convert foreground color
    switch (style.fg_color) {
        .none => {},
        .palette => |idx| {
            attrs.fg_idx = @intCast(idx);
        },
        .rgb => |rgb| {
            // Convert RGB struct to u32: 0xRRGGBB
            attrs.fg = (@as(u32, rgb.r) << 16) | (@as(u32, rgb.g) << 8) | @as(u32, rgb.b);
        },
    }

    // Convert background color
    switch (style.bg_color) {
        .none => {},
        .palette => |idx| {
            attrs.bg_idx = @intCast(idx);
        },
        .rgb => |rgb| {
            // Convert RGB struct to u32: 0xRRGGBB
            attrs.bg = (@as(u32, rgb.r) << 16) | (@as(u32, rgb.g) << 8) | @as(u32, rgb.b);
        },
    }

    // Convert underline color
    switch (style.underline_color) {
        .none => {},
        .palette => |idx| {
            _ = idx;
        },
        .rgb => |rgb| {
            attrs.ul_color = (@as(u32, rgb.r) << 16) | (@as(u32, rgb.g) << 8) | @as(u32, rgb.b);
        },
    }

    // Convert flags
    attrs.bold = style.flags.bold;
    attrs.dim = style.flags.faint;
    attrs.italic = style.flags.italic;
    attrs.reverse = style.flags.inverse;
    attrs.blink = style.flags.blink;
    attrs.strikethrough = style.flags.strikethrough;

    // Handle underline variants
    attrs.ul_style = switch (style.flags.underline) {
        .none => .none,
        .single => .single,
        .double => .double,
        .curly => .curly,
        .dotted => .dotted,
        .dashed => .dashed,
    };

    return attrs;
}

/// Captured screen state for building redraw notifications
pub const RenderMode = enum { full, incremental };

/// State passed between redraw helper functions
const RedrawContext = struct {
    builder: *redraw.RedrawBuilder,
    temp_alloc: std.mem.Allocator,
    pty_id: usize,
    rows: usize,
    cols: usize,
    default_style: ghostty_vt.Style,
    styles_map: std.AutoHashMap(u64, u32),
    next_style_id: u32,
    last_style: ?ghostty_vt.Style,
    last_style_id: u32,
};

fn emitTitle(builder: *redraw.RedrawBuilder, pty_instance: *Pty, mode: RenderMode) !void {
    if (mode == .full or pty_instance.title_dirty) {
        try builder.title(@intCast(pty_instance.id), pty_instance.title.items);
        pty_instance.title_dirty = false;
    }
}

fn emitResize(builder: *redraw.RedrawBuilder, pty_id: usize, rows: usize, cols: usize) !void {
    try builder.resize(@intCast(pty_id), @intCast(rows), @intCast(cols));
}

fn initStylesContext(temp_alloc: std.mem.Allocator, builder: *redraw.RedrawBuilder, pty_id: usize, rows: usize, cols: usize) !RedrawContext {
    var styles_map = std.AutoHashMap(u64, u32).init(temp_alloc);
    const default_style: ghostty_vt.Style = .{
        .fg_color = .none,
        .bg_color = .none,
        .underline_color = .none,
        .flags = .{},
    };
    const default_hash = std.hash.Wyhash.hash(0, std.mem.asBytes(&default_style));
    try styles_map.put(default_hash, 0);
    try builder.style(0, .{});

    return .{
        .builder = builder,
        .temp_alloc = temp_alloc,
        .pty_id = pty_id,
        .rows = rows,
        .cols = cols,
        .default_style = default_style,
        .styles_map = styles_map,
        .next_style_id = 1,
        .last_style = null,
        .last_style_id = 0,
    };
}

fn resolveStyle(ctx: *RedrawContext, vt_style: ghostty_vt.Style) !u32 {
    if (ctx.last_style) |last| {
        if (std.meta.eql(last, vt_style)) {
            return ctx.last_style_id;
        }
    }

    const style_hash = std.hash.Wyhash.hash(0, std.mem.asBytes(&vt_style));
    if (ctx.styles_map.get(style_hash)) |id| {
        ctx.last_style = vt_style;
        ctx.last_style_id = id;
        return id;
    }

    const style_id = ctx.next_style_id;
    ctx.next_style_id += 1;
    try ctx.styles_map.put(style_hash, style_id);
    const attrs = getStyleAttributes(vt_style);
    try ctx.builder.style(style_id, attrs);
    ctx.last_style = vt_style;
    ctx.last_style_id = style_id;
    return style_id;
}

const CellSlices = struct {
    raw: []const ghostty_vt.page.Cell,
    style: []const ghostty_vt.Style,
    grapheme: []const []const u21,
};

fn encodeGraphemeToUtf8(temp_alloc: std.mem.Allocator, cluster: []const u21) ![]const u8 {
    if (cluster.len == 0) return try temp_alloc.dupe(u8, " ");

    var utf8_buf: [4]u8 = undefined;
    var stack_buf: [64]u8 = undefined;
    var stack_len: usize = 0;
    for (cluster) |cp| {
        if (stack_len + 4 > stack_buf.len) break;
        const len = std.unicode.utf8Encode(cp, &utf8_buf) catch continue;
        @memcpy(stack_buf[stack_len..][0..len], utf8_buf[0..len]);
        stack_len += len;
    }
    return try temp_alloc.dupe(u8, stack_buf[0..stack_len]);
}

fn resolveCellText(
    ctx: *RedrawContext,
    raw_cell: ghostty_vt.page.Cell,
    grapheme_slice: []const u21,
    is_direct_color: bool,
) ![]const u8 {
    if (is_direct_color) return " ";

    var one_grapheme_buf: [1]u21 = undefined;
    const cluster: []const u21 = switch (raw_cell.content_tag) {
        .codepoint => blk: {
            if (raw_cell.content.codepoint != 0) {
                one_grapheme_buf[0] = raw_cell.content.codepoint;
                break :blk &one_grapheme_buf;
            }
            break :blk &[_]u21{};
        },
        .codepoint_grapheme => blk: {
            const base_cp = raw_cell.content.codepoint;
            const full_cluster = try ctx.temp_alloc.alloc(u21, 1 + grapheme_slice.len);
            full_cluster[0] = base_cp;
            @memcpy(full_cluster[1..], grapheme_slice);
            break :blk full_cluster;
        },
        else => &[_]u21{' '},
    };
    return try encodeGraphemeToUtf8(ctx.temp_alloc, cluster);
}

fn detectRepeat(
    raw_cell: ghostty_vt.page.Cell,
    slices: CellSlices,
    x: usize,
    cols: usize,
    is_direct_color: bool,
) usize {
    var repeat: usize = 1;
    var next_x = x + 1;
    if (raw_cell.wide == .wide) next_x += 1;

    while (next_x < cols) {
        const next_raw = slices.raw[next_x];
        if (raw_cell.wide != next_raw.wide) break;
        if (!cellsMatch(raw_cell, next_raw, slices.grapheme, x, next_x, is_direct_color)) break;

        repeat += 1;
        next_x += 1;
        if (next_raw.wide == .wide) next_x += 1;
    }
    return repeat;
}

fn cellsMatch(
    raw_cell: ghostty_vt.page.Cell,
    next_raw: ghostty_vt.page.Cell,
    grapheme_slice: []const []const u21,
    x: usize,
    next_x: usize,
    is_direct_color: bool,
) bool {
    if (next_raw.content_tag != raw_cell.content_tag or next_raw.style_id != raw_cell.style_id) return false;

    if (is_direct_color) {
        if (raw_cell.content_tag == .bg_color_rgb) {
            return std.meta.eql(raw_cell.content.color_rgb, next_raw.content.color_rgb);
        } else if (raw_cell.content_tag == .bg_color_palette) {
            return raw_cell.content.color_palette == next_raw.content.color_palette;
        }
        return false;
    }

    if (raw_cell.content_tag == .codepoint) {
        return next_raw.content.codepoint == raw_cell.content.codepoint;
    } else if (raw_cell.content_tag == .codepoint_grapheme) {
        return std.mem.eql(u21, grapheme_slice[x], grapheme_slice[next_x]);
    }
    return true;
}

fn emitRow(ctx: *RedrawContext, y: usize, slices: CellSlices) !void {
    var cells_buf = std.ArrayList(redraw.UIEvent.Write.Cell).empty;
    var last_hl_id: u32 = 0;
    var x: usize = 0;

    while (x < ctx.cols) {
        const raw_cell = slices.raw[x];
        if (raw_cell.wide == .spacer_tail) {
            x += 1;
            continue;
        }

        var vt_style = if (raw_cell.style_id > 0) slices.style[x] else ctx.default_style;
        var is_direct_color = false;

        if (raw_cell.content_tag == .bg_color_rgb) {
            const cell_rgb = raw_cell.content.color_rgb;
            vt_style.bg_color = .{ .rgb = .{ .r = cell_rgb.r, .g = cell_rgb.g, .b = cell_rgb.b } };
            is_direct_color = true;
        } else if (raw_cell.content_tag == .bg_color_palette) {
            vt_style.bg_color = .{ .palette = raw_cell.content.color_palette };
            is_direct_color = true;
        }

        const style_id = try resolveStyle(ctx, vt_style);
        const text = try resolveCellText(ctx, raw_cell, slices.grapheme[x], is_direct_color);
        const repeat = detectRepeat(raw_cell, slices, x, ctx.cols, is_direct_color);

        const hl_id_to_send: ?u32 = if (style_id != last_hl_id) style_id else null;
        if (hl_id_to_send) |id| last_hl_id = id;

        try cells_buf.append(ctx.temp_alloc, .{
            .grapheme = text,
            .style_id = hl_id_to_send,
            .repeat = if (repeat > 1) @intCast(repeat) else null,
            .width = if (raw_cell.wide == .wide) 2 else null,
        });

        x += repeat;
        if (raw_cell.wide == .wide) x += repeat;
    }

    if (cells_buf.items.len > 0) {
        try ctx.builder.write(@intCast(ctx.pty_id), @intCast(y), 0, cells_buf.items);
    }
}

fn emitRows(ctx: *RedrawContext, rs: *ghostty_vt.RenderState, effective_mode: RenderMode) !void {
    const row_data_slice = rs.row_data.slice();
    const row_cells = row_data_slice.items(.cells);
    const row_dirties = row_data_slice.items(.dirty);

    for (0..ctx.rows) |y| {
        if (effective_mode == .incremental and !row_dirties[y]) continue;
        row_dirties[y] = false;

        const rs_cells = row_cells[y];
        const rs_cells_slice = rs_cells.slice();
        const slices: CellSlices = .{
            .raw = rs_cells_slice.items(.raw),
            .style = rs_cells_slice.items(.style),
            .grapheme = rs_cells_slice.items(.grapheme),
        };
        try emitRow(ctx, y, slices);
    }
}

fn emitCursor(builder: *redraw.RedrawBuilder, pty_id: usize, rs: *const ghostty_vt.RenderState) !void {
    const cursor_visible = rs.cursor.visible and rs.cursor.viewport != null;
    if (rs.cursor.viewport) |vp| {
        try builder.cursorPos(@intCast(pty_id), @intCast(vp.y), @intCast(vp.x), cursor_visible);
    } else {
        try builder.cursorPos(@intCast(pty_id), @intCast(rs.cursor.active.y), @intCast(rs.cursor.active.x), cursor_visible);
    }
    const shape: redraw.UIEvent.CursorShape.Shape = switch (rs.cursor.visual_style) {
        .block, .block_hollow => .block,
        .bar => .beam,
        .underline => .underline,
    };
    try builder.cursorShape(@intCast(pty_id), shape);
}

fn emitSelection(builder: *redraw.RedrawBuilder, pty_id: usize, rs: *const ghostty_vt.RenderState) !void {
    const row_selections = rs.row_data.slice().items(.selection);
    var sel_start_row: ?u16 = null;
    var sel_start_col: ?u16 = null;
    var sel_end_row: ?u16 = null;
    var sel_end_col: ?u16 = null;

    for (row_selections, 0..) |sel_range, y| {
        if (sel_range) |range| {
            if (sel_start_row == null) {
                sel_start_row = @intCast(y);
                sel_start_col = @intCast(range[0]);
            }
            sel_end_row = @intCast(y);
            sel_end_col = @intCast(range[1]);
        }
    }
    try builder.selection(@intCast(pty_id), sel_start_row, sel_start_col, sel_end_row, sel_end_col);
}

/// Build redraw message directly from PTY render state
fn buildRedrawMessageFromPty(
    allocator: std.mem.Allocator,
    pty_instance: *Pty,
    mode: RenderMode,
) ![]u8 {
    var builder = redraw.RedrawBuilder.init(allocator);
    defer builder.deinit();

    var temp_arena = std.heap.ArenaAllocator.init(allocator);
    defer temp_arena.deinit();
    const temp_alloc = temp_arena.allocator();

    const mouse_shape = mouse_shape: {
        pty_instance.terminal_mutex.lock();
        defer pty_instance.terminal_mutex.unlock();

        // Skip rendering during synchronized output mode - the application is in the
        // middle of an atomic update and the terminal state may be inconsistent
        if (pty_instance.terminal.modes.get(.synchronized_output)) {
            return error.SynchronizedOutput;
        }

        pty_instance.render_state.update(pty_instance.allocator, &pty_instance.terminal) catch |err| {
            // If update fails, reset render state to recover from potentially corrupt state
            log.warn("render_state.update failed: {}, resetting render state", .{err});
            pty_instance.render_state.deinit(pty_instance.allocator);
            pty_instance.render_state = .empty;
            return err;
        };

        // Emit title while mutex is held (title.items is modified by read thread)
        try emitTitle(&builder, pty_instance, mode);

        break :mouse_shape mapMouseShape(pty_instance.terminal.mouse_shape);
    };

    const rs = &pty_instance.render_state;

    var effective_mode = mode;
    if (rs.dirty == .full) effective_mode = .full;
    rs.dirty = .false;

    const rows = rs.rows;
    const cols = rs.cols;

    if (effective_mode == .full) {
        try emitResize(&builder, pty_instance.id, rows, cols);
    }

    var ctx = try initStylesContext(temp_alloc, &builder, pty_instance.id, rows, cols);
    try emitRows(&ctx, rs, effective_mode);
    try emitCursor(&builder, pty_instance.id, rs);
    try builder.mouseShape(@intCast(pty_instance.id), mouse_shape);
    try emitSelection(&builder, pty_instance.id, rs);

    try builder.flush();
    return builder.build();
}

const Client = struct {
    /// Monotonic id assigned by the server at onAccept time, sourced from
    /// `Server.next_client_id`. Stable for the lifetime of the connection
    /// and never reused. Two consumers:
    ///   1. Plug lifecycle events: exposed to plugs via the
    ///      client_connected / client_disconnected / pty_attach /
    ///      pty_detach notifications and addressable through
    ///      notify_plug_client.
    ///   2. The deterministic broker-pick key for the client-broker RPC
    ///      pattern (lowest id among attached clients).
    /// Resets on server restart — clients re-attach and pick a new lowest.
    /// Default is 0 so hand-rolled Client literals in tests keep compiling —
    /// the production path always overwrites it in onAccept.
    id: usize = 0,
    fd: posix.fd_t,
    server: *Server,
    // 4096 bytes is sufficient for typical RPC messages while staying
    // small enough for stack allocation. Larger messages are handled
    // via msg_buffer accumulation.
    recv_buffer: [4096]u8 = undefined,
    msg_buffer: std.ArrayList(u8),
    send_buffer: ?[]u8 = null,
    send_offset: usize = 0,
    send_queue: std.ArrayList([]u8),
    attached_ptys: std.ArrayList(usize),
    closing: bool = false,
    macos_option_as_alt: key_encode.OptionAsAlt = .false,
    /// Non-null when this client is a registered plug process.
    plug_name: ?[]const u8 = null,
    /// Event subscriptions for this plug (e.g., "pty_exited", "cwd_changed", or "*").
    plug_subscriptions: ?[]const []const u8 = null,
    /// Whether this client has been sent existing plug notifications.
    notified_plugs: bool = false,

    /// Check if this plug client is subscribed to the given event name.
    fn isSubscribedPlug(self: *const Client, event_name: []const u8) bool {
        const subs = self.plug_subscriptions orelse return false;
        for (subs) |s| {
            if (std.mem.eql(u8, s, "*") or std.mem.eql(u8, s, event_name)) {
                return true;
            }
        }
        return false;
    }

    // Map style ID to its last known definition hash/attributes to detect changes
    // We store the Attributes struct directly.
    // style_cache: std.AutoHashMap(u16, redraw.UIEvent.Style.Attributes),

    fn sendData(self: *Client, loop: *io.Loop, data: []const u8) !void {
        if (self.closing) return;

        std.debug.assert(data.len > 0);
        std.debug.assert(data.len <= LIMITS.MESSAGE_SIZE_MAX);
        std.debug.assert(self.fd >= 0);

        const buf = try self.server.allocator.dupe(u8, data);
        errdefer self.server.allocator.free(buf);

        // If there's a pending send, queue this one
        if (self.send_buffer != null) {
            if (self.send_queue.items.len >= LIMITS.SEND_QUEUE_MAX) {
                self.server.allocator.free(buf);
                return error.SendQueueFull;
            }
            try self.send_queue.append(self.server.allocator, buf);
            return;
        }

        // Otherwise send immediately
        self.send_buffer = buf;
        _ = try loop.send(self.fd, buf, .{
            .ptr = self,
            .cb = onSendComplete,
        });
    }

    fn onSendComplete(loop: *io.Loop, completion: io.Completion) anyerror!void {
        const client = completion.userdataCast(Client);
        const allocator = client.server.allocator;

        switch (completion.result) {
            .send => |n| {
                const buf = client.send_buffer orelse return;
                client.send_offset += n;

                // Check for partial send
                if (client.send_offset < buf.len) {
                    // Re-arm for remaining bytes
                    _ = try loop.send(client.fd, buf[client.send_offset..], .{
                        .ptr = client,
                        .cb = onSendComplete,
                    });
                    return;
                }

                // Buffer fully sent, free it
                allocator.free(buf);
                client.send_buffer = null;
                client.send_offset = 0;

                // If client is closing, finish cleanup
                if (client.closing) {
                    client.finishClose(loop);
                    return;
                }

                // Send next queued message if any
                if (client.send_queue.items.len > 0) {
                    const next_buf = client.send_queue.orderedRemove(0);
                    client.send_buffer = next_buf;
                    _ = try loop.send(client.fd, next_buf, .{
                        .ptr = client,
                        .cb = onSendComplete,
                    });
                }
            },
            .err => |err| {
                if (err != error.BrokenPipe) {
                    log.err("Send failed: {}", .{err});
                }
                // Free current buffer
                if (client.send_buffer) |buf| {
                    allocator.free(buf);
                    client.send_buffer = null;
                    client.send_offset = 0;
                }
                // Clear queue on error
                for (client.send_queue.items) |buf| {
                    allocator.free(buf);
                }
                client.send_queue.clearRetainingCapacity();

                if (client.closing) {
                    client.finishClose(loop);
                }
            },
            else => unreachable,
        }
    }

    fn finishClose(self: *Client, loop: *io.Loop) void {
        const server = self.server;
        const allocator = server.allocator;

        // Non-plug clients fan out pty_detach for any still-attached PTYs,
        // then client_disconnected as the final farewell. The latter only
        // fires if client_connected was fired (notified_plugs flips on the
        // first non-register_plug RPC), so a client that bails during the
        // initial handshake never produces an orphan disconnect.
        // Plug clients announce via broadcastPlugDisconnected below.
        if (self.plug_name == null) {
            for (self.attached_ptys.items) |pty_id| {
                server.forwardPtyClientEvent("pty_detach", self.id, pty_id);
            }
            if (self.notified_plugs) {
                server.forwardClientEvent("client_disconnected", self.id);
            }
        }

        // Free any remaining queued sends
        for (self.send_queue.items) |buf| {
            allocator.free(buf);
        }
        self.send_queue.deinit(allocator);
        self.msg_buffer.deinit(allocator);
        self.attached_ptys.deinit(allocator);

        // Clean up plug registration and pending call forwards
        if (self.plug_name) |name| {
            // Error out in-flight calls to this plug
            server.cleanupPlugForwards(self);

            // Mark the managed plug as unregistered and check for deferred restart
            var deferred_restart_mp: ?*ManagedPlug = null;
            for (server.managed_plugs.items) |*mp| {
                if (std.mem.eql(u8, mp.name, name)) {
                    mp.registered = false;
                    // Process already exited — onPlugExit deferred restart
                    if (mp.pid == null and mp.restart and !mp.killed_by_server and !server.shutting_down) {
                        mp.restart_count += 1;
                        deferred_restart_mp = mp;
                    }
                    break;
                }
            }

            _ = server.plugs.remove(name);

            // Notify TUI clients that this plug disconnected
            server.broadcastPlugDisconnected(loop, name) catch |err| {
                log.err("Failed to broadcast plug_disconnected: {}", .{err});
            };

            allocator.free(name);
            self.plug_name = null;

            // Restart after cleanup to avoid DuplicatePlugName race
            if (deferred_restart_mp) |mp| {
                server.schedulePlugRestart(loop, mp) catch |err| {
                    log.err("Failed to schedule restart for '{s}': {}", .{ mp.name, err });
                };
            }
        }

        // Remove pending forwards originated by this client
        server.cleanupOriginatorForwards(self);
        if (self.plug_subscriptions) |subs| {
            for (subs) |s| allocator.free(s);
            allocator.free(subs);
            self.plug_subscriptions = null;
        }

        // Remove from server's client list
        for (server.clients.items, 0..) |c, i| {
            if (c == self) {
                _ = server.clients.swapRemove(i);
                break;
            }
        }

        _ = loop.close(self.fd, .{
            .ptr = null,
            .cb = struct {
                fn noop(_: *io.Loop, _: io.Completion) anyerror!void {}
            }.noop,
        }) catch {};

        allocator.destroy(self);
        std.log.debug("Total clients: {}", .{server.clients.items.len});
        server.checkExit() catch {};
    }

    fn processMessage(self: *Client, loop: *io.Loop, msg: rpc.Message) !void {
        std.debug.assert(!self.closing);
        std.debug.assert(self.fd >= 0);

        switch (msg) {
            .request => |req| {
                try self.handleRpcRequest(loop, req);
            },
            .notification => |notif| {
                try self.handleNotification(notif);
            },
            .response => |resp| {
                // Plug clients send responses to forwarded calls
                if (self.plug_name != null) {
                    self.server.handlePlugResponse(resp);
                }
            },
        }
    }

    /// Handle RPC request, send response with result.
    fn handleRpcRequest(self: *Client, loop: *io.Loop, req: rpc.Request) !void {
        std.debug.assert(req.method.len > 0);

        // Async-broker requests (currently only `break_pane`) own their own
        // response lifecycle: they may send the Response synchronously
        // (refusal short-circuits) OR defer it until the broker replies via
        // a `break_pane_reply` notification. Returning early here keeps the
        // synchronous-response wrapper below from sending an extra Response.
        if (std.mem.eql(u8, req.method, "break_pane")) {
            return self.server.handleBreakPane(self, req.msgid, req.params);
        }

        // call_plug is special: response is deferred until the plug replies
        if (std.mem.eql(u8, req.method, "call_plug")) {
            self.server.handleCallPlugDeferred(self, req.msgid, req.params) catch |err| {
                return self.sendErrorResponse(loop, req.msgid, err);
            };
            return; // response will be sent later by handlePlugResponse
        }

        const result = self.server.handleRequest(self, req.method, req.params) catch |err| {
            return self.sendErrorResponse(loop, req.msgid, err);
        };
        defer result.deinit(self.server.allocator);

        const response_arr = try self.server.allocator.alloc(msgpack.Value, 4);
        defer self.server.allocator.free(response_arr);
        response_arr[0] = msgpack.Value{ .unsigned = 1 }; // type
        response_arr[1] = msgpack.Value{ .unsigned = req.msgid }; // msgid
        response_arr[2] = msgpack.Value.nil; // no error
        response_arr[3] = result; // result

        const response_value = msgpack.Value{ .array = response_arr };
        const response_bytes = try msgpack.encodeFromValue(self.server.allocator, response_value);
        defer self.server.allocator.free(response_bytes);

        std.debug.assert(response_bytes.len <= LIMITS.MESSAGE_SIZE_MAX);
        try self.sendData(loop, response_bytes);
    }

    fn sendErrorResponse(self: *Client, loop: *io.Loop, msgid: u32, err: anyerror) !void {
        const response_arr = try self.server.allocator.alloc(msgpack.Value, 4);
        defer self.server.allocator.free(response_arr);
        response_arr[0] = msgpack.Value{ .unsigned = 1 }; // type
        response_arr[1] = msgpack.Value{ .unsigned = msgid }; // msgid
        response_arr[2] = msgpack.Value{ .string = @errorName(err) }; // error
        response_arr[3] = msgpack.Value.nil; // no result

        const response_value = msgpack.Value{ .array = response_arr };
        const response_bytes = try msgpack.encodeFromValue(self.server.allocator, response_value);
        defer self.server.allocator.free(response_bytes);

        std.debug.assert(response_bytes.len <= LIMITS.MESSAGE_SIZE_MAX);
        try self.sendData(loop, response_bytes);
    }

    /// Send a `{ok, reason?}` map Response for a `break_pane` request.
    ///
    /// Used by every terminal state of the broker dance: synchronous
    /// `session_not_attached` refusal at request time, broker reply
    /// arrival (`ok=true` or refusal token), deadline-sweep timeout,
    /// and broker disconnect. `reason` is omitted when null
    /// (success replies use `{ok=true}` only).
    fn sendBreakPaneResponse(self: *Client, loop: *io.Loop, msgid: u32, ok: bool, reason: ?[]const u8) !void {
        const allocator = self.server.allocator;

        const map_len: usize = if (reason) |_| 2 else 1;
        const map_items = try allocator.alloc(msgpack.Value.KeyValue, map_len);
        defer allocator.free(map_items);

        map_items[0] = .{
            .key = .{ .string = "ok" },
            .value = .{ .boolean = ok },
        };
        if (reason) |r| {
            map_items[1] = .{
                .key = .{ .string = "reason" },
                .value = .{ .string = r },
            };
        }

        const response_arr = try allocator.alloc(msgpack.Value, 4);
        defer allocator.free(response_arr);
        response_arr[0] = msgpack.Value{ .unsigned = 1 }; // type=Response
        response_arr[1] = msgpack.Value{ .unsigned = msgid };
        response_arr[2] = msgpack.Value.nil; // no error
        response_arr[3] = msgpack.Value{ .map = map_items };

        const response_value = msgpack.Value{ .array = response_arr };
        const response_bytes = try msgpack.encodeFromValue(allocator, response_value);
        defer allocator.free(response_bytes);

        std.debug.assert(response_bytes.len <= LIMITS.MESSAGE_SIZE_MAX);
        try self.sendData(loop, response_bytes);
    }

    /// Dispatch notification to appropriate handler.
    fn handleNotification(self: *Client, notif: rpc.Notification) !void {
        std.debug.assert(notif.method.len > 0);

        if (std.mem.eql(u8, notif.method, "write_pty")) {
            try self.handleWritePty(notif);
        } else if (std.mem.eql(u8, notif.method, "paste_input")) {
            try self.handlePasteInput(notif);
        } else if (std.mem.eql(u8, notif.method, "key_input") or
            std.mem.eql(u8, notif.method, "key_release"))
        {
            try self.handleKeyEvent(notif);
        } else if (std.mem.eql(u8, notif.method, "mouse_input")) {
            try self.handleMouseInput(notif);
        } else if (std.mem.eql(u8, notif.method, "resize_pty")) {
            try self.handleResizePty(notif);
        } else if (std.mem.eql(u8, notif.method, "detach_pty")) {
            try self.handleDetachPty(notif);
        } else if (std.mem.eql(u8, notif.method, "focus_event")) {
            try self.handleFocusEvent(notif);
        } else if (std.mem.eql(u8, notif.method, "color_response")) {
            try self.handleColorResponse(notif);
        } else if (std.mem.eql(u8, notif.method, "break_pane_reply")) {
            try self.server.handleBreakPaneReply(self, notif);
        } else if (std.mem.eql(u8, notif.method, "session_file_changed")) {
            try self.handleSessionFileChanged(notif);
        } else if (std.mem.startsWith(u8, notif.method, "plug.")) {
            if (self.plug_name) |name| {
                try self.server.forwardPlugNotification(self.server.loop, notif, name);
            }
        }
    }

    /// Write binary data to PTY input.
    fn handleWritePty(self: *Client, notif: rpc.Notification) !void {
        if (notif.params != .array or notif.params.array.len < 2) {
            log.warn("write_pty notification: invalid params", .{});
            return;
        }

        const pty_id = parsePtyId(notif.params.array[0]) orelse {
            log.warn("write_pty notification: invalid pty_id type", .{});
            return;
        };

        const input_data = parseInputData(notif.params.array[1]) orelse {
            log.warn("write_pty notification: invalid data type", .{});
            return;
        };

        if (self.server.ptys.get(pty_id)) |pty_instance| {
            self.promoteSizeOwner(pty_instance);

            _ = posix.write(pty_instance.process.master, input_data) catch |err| {
                logPtyWriteError(err);
            };
        } else {
            log.warn("write_pty notification: PTY {} not found", .{pty_id});
        }
    }

    /// Promote this client to size owner for all attached PTYs.
    /// Mirrors tmux: interacting with any pane makes this client control
    /// the terminal size for every pane, not just the one receiving input.
    fn promoteSizeOwner(self: *Client, trigger_pty: *Pty) void {
        if (trigger_pty.size_owner == self) return;

        log.info("promoting client {} to size owner (triggered by pty={})", .{ self.fd, trigger_pty.id });
        for (self.attached_ptys.items) |pid| {
            if (self.server.ptys.get(pid)) |pty_inst| {
                pty_inst.size_owner = self;
            }
        }
    }

    /// Handle clipboard paste with optional bracketed paste mode.
    fn handlePasteInput(self: *Client, notif: rpc.Notification) !void {
        if (notif.params != .array or notif.params.array.len < 2) {
            log.warn("paste_input notification: invalid params", .{});
            return;
        }

        const pty_id = parsePtyId(notif.params.array[0]) orelse {
            log.warn("paste_input notification: invalid pty_id type", .{});
            return;
        };

        const paste_data = parseInputData(notif.params.array[1]) orelse {
            log.warn("paste_input notification: invalid data type", .{});
            return;
        };

        if (self.server.ptys.get(pty_id)) |pty_instance| {
            pty_instance.terminal_mutex.lock();
            const bracketed = pty_instance.terminal.modes.get(.bracketed_paste);
            pty_instance.terminal_mutex.unlock();

            if (bracketed) {
                writeAllFd(pty_instance.process.master, "\x1b[200~") catch |err| {
                    logPtyWriteError(err);
                };
                writeAllFd(pty_instance.process.master, paste_data) catch |err| {
                    logPtyWriteError(err);
                };
                writeAllFd(pty_instance.process.master, "\x1b[201~") catch |err| {
                    logPtyWriteError(err);
                };
            } else {
                const mutable_data = self.server.allocator.dupe(u8, paste_data) catch |err| {
                    log.err("Failed to allocate paste buffer: {}", .{err});
                    return;
                };
                defer self.server.allocator.free(mutable_data);
                std.mem.replaceScalar(u8, mutable_data, '\n', '\r');
                writeAllFd(pty_instance.process.master, mutable_data) catch |err| {
                    logPtyWriteError(err);
                };
            }
        } else {
            log.warn("paste_input notification: PTY {} not found", .{pty_id});
        }
    }

    /// Handle keyboard press/release events.
    fn handleKeyEvent(self: *Client, notif: rpc.Notification) !void {
        if (notif.params != .array or notif.params.array.len < 2) {
            log.warn("key_input notification: invalid params", .{});
            return;
        }

        const is_release = std.mem.eql(u8, notif.method, "key_release");
        const pty_id = parsePtyId(notif.params.array[0]) orelse {
            log.warn("key_input notification: invalid pty_id type", .{});
            return;
        };
        const key_map = notif.params.array[1];

        if (self.server.ptys.get(pty_id)) |pty_instance| {
            self.promoteSizeOwner(pty_instance);

            const action: ghostty_vt.input.KeyAction = if (is_release) .release else .press;
            const key = key_parse.parseKeyMapWithAction(key_map, action) catch |err| {
                log.err("Failed to parse key map: {}", .{err});
                return;
            };

            var encode_buf: [32]u8 = undefined;
            var writer = std.Io.Writer.fixed(&encode_buf);

            pty_instance.terminal_mutex.lock();
            key_encode.encode(&writer, key, &pty_instance.terminal, self.macos_option_as_alt) catch |err| {
                log.err("Failed to encode key: {}", .{err});
                pty_instance.terminal_mutex.unlock();
                return;
            };

            const encoded = writer.buffered();
            if (encoded.len > 0 and !key.key.modifier()) {
                pty_instance.terminal.scrollViewport(.bottom);
                pty_instance.terminal.screens.active.select(null) catch {};
            }
            pty_instance.terminal_mutex.unlock();

            if (encoded.len > 0 and !key.key.modifier()) {
                _ = posix.write(pty_instance.pipe_fds[1], "x") catch {};
            }

            if (encoded.len > 0) {
                _ = posix.write(pty_instance.process.master, encoded) catch |err| {
                    logPtyWriteError(err);
                };
            }
        } else {
            log.warn("key_input notification: PTY {} not found", .{pty_id});
        }
    }

    /// Handle mouse input (click, drag, scroll, motion).
    fn handleMouseInput(self: *Client, notif: rpc.Notification) !void {
        if (notif.params != .array or notif.params.array.len < 2) {
            log.warn("mouse_input notification: invalid params", .{});
            return;
        }

        const pty_id = parsePtyId(notif.params.array[0]) orelse {
            log.warn("mouse_input notification: invalid pty_id type", .{});
            return;
        };
        const mouse_map = notif.params.array[1];

        if (self.server.ptys.get(pty_id)) |pty_instance| {
            const mouse = key_parse.parseMouseMap(mouse_map) catch |err| {
                log.err("Failed to parse mouse map: {}", .{err});
                return;
            };

            const is_wheel = switch (mouse.button) {
                .wheel_up, .wheel_down, .wheel_left, .wheel_right => true,
                else => false,
            };

            const State = struct {
                terminal: mouse_encode.TerminalState,
                active_screen: ghostty_vt.ScreenSet.Key,
            };
            const state: State = state: {
                pty_instance.terminal_mutex.lock();
                defer pty_instance.terminal_mutex.unlock();
                break :state .{
                    .terminal = mouse_encode.TerminalState.init(&pty_instance.terminal),
                    .active_screen = pty_instance.terminal.screens.active_key,
                };
            };

            if (is_wheel and state.terminal.flags.mouse_event == .none) {
                try self.handleMouseWheel(pty_instance, mouse, state.terminal, state.active_screen);
            } else if (mouse.button == .left and state.terminal.flags.mouse_event == .none) {
                try self.handleMouseSelection(pty_instance, mouse);
            } else {
                try self.handleMouseReport(pty_instance, mouse, state.terminal);
            }
        } else {
            log.warn("mouse_input notification: PTY {} not found", .{pty_id});
        }
    }

    /// Handle mouse wheel scrolling.
    fn handleMouseWheel(
        self: *Client,
        pty_instance: *Pty,
        mouse: key_parse.MouseEvent,
        terminal: mouse_encode.TerminalState,
        active_screen: ghostty_vt.ScreenSet.Key,
    ) !void {
        _ = self;
        if (active_screen == .alternate and terminal.modes.get(.mouse_alternate_scroll)) {
            const seq: []const u8 = if (terminal.modes.get(.cursor_keys))
                (if (mouse.button == .wheel_up) "\x1bOA" else "\x1bOB")
            else
                (if (mouse.button == .wheel_up) "\x1b[A" else "\x1b[B");
            _ = posix.write(pty_instance.process.master, seq) catch |err| {
                logPtyWriteError(err);
            };
        } else {
            const delta: isize = switch (mouse.button) {
                .wheel_up => -1,
                .wheel_down => 1,
                else => 0,
            };
            if (delta != 0) {
                pty_instance.terminal_mutex.lock();
                pty_instance.terminal.scrollViewport(.{ .delta = delta });
                pty_instance.terminal_mutex.unlock();
                _ = posix.write(pty_instance.pipe_fds[1], "x") catch {};
            }
        }
    }

    /// Handle left-click selection: single, double, triple, and drag.
    fn handleMouseSelection(self: *Client, pty_instance: *Pty, mouse: key_parse.MouseEvent) !void {
        _ = self;
        const col: u16 = @intFromFloat(@max(0, @floor(mouse.x)));
        const row: u16 = @intFromFloat(@max(0, @floor(mouse.y)));
        const CLICK_INTERVAL_MS: i64 = 500;

        switch (mouse.type) {
            .press => {
                // Update click count based on timing
                const now = std.time.milliTimestamp();
                if (pty_instance.left_click_count > 0 and
                    (now - pty_instance.left_click_time) < CLICK_INTERVAL_MS)
                {
                    pty_instance.left_click_count += 1;
                    if (pty_instance.left_click_count > 3) {
                        pty_instance.left_click_count = 1;
                    }
                } else {
                    pty_instance.left_click_count = 1;
                }
                pty_instance.left_click_time = now;

                pty_instance.terminal_mutex.lock();
                defer pty_instance.terminal_mutex.unlock();

                const screen = pty_instance.terminal.screens.active;
                const terminal_cols = pty_instance.terminal.cols;
                const clamped_col: u16 = @min(col, terminal_cols -| 1);
                const clamped_row: u16 = @min(row, pty_instance.terminal.rows -| 1);
                const pin = screen.pages.pin(.{ .viewport = .{
                    .x = clamped_col,
                    .y = clamped_row,
                } }) orelse return;

                // Store the pin so it survives viewport scrolling during drag
                pty_instance.selection_start = pin;

                switch (pty_instance.left_click_count) {
                    1 => screen.select(null) catch {},
                    2 => {
                        if (screen.selectWord(pin, &[_]u21{})) |sel| {
                            screen.select(sel) catch {};
                        }
                    },
                    3 => {
                        if (screen.selectLine(.{ .pin = pin })) |sel| {
                            screen.select(sel) catch {};
                        }
                    },
                    else => {},
                }
                _ = posix.write(pty_instance.pipe_fds[1], "x") catch {};
            },
            .drag => {
                if (pty_instance.selection_start) |start| {
                    pty_instance.terminal_mutex.lock();
                    defer pty_instance.terminal_mutex.unlock();

                    const screen = pty_instance.terminal.screens.active;
                    const terminal_rows = pty_instance.terminal.rows;
                    const terminal_cols = pty_instance.terminal.cols;

                    // Auto-scroll when dragging beyond viewport edges
                    const raw_y = mouse.y;
                    if (raw_y < 0) {
                        pty_instance.terminal.scrollViewport(.{ .delta = -1 });
                    } else if (raw_y >= @as(f64, @floatFromInt(terminal_rows))) {
                        pty_instance.terminal.scrollViewport(.{ .delta = 1 });
                    }

                    // Clamp to valid viewport range after scrolling
                    const clamped_col: u16 = @min(col, terminal_cols -| 1);
                    const clamped_row: u16 = @intFromFloat(@max(0, @min(
                        @floor(raw_y),
                        @as(f64, @floatFromInt(terminal_rows -| 1)),
                    )));

                    // start is already a Pin (stored during press event)
                    const start_pin = start;
                    const end_pin = screen.pages.pin(.{ .viewport = .{
                        .x = clamped_col,
                        .y = clamped_row,
                    } }) orelse return;

                    switch (pty_instance.left_click_count) {
                        1 => {
                            const sel = ghostty_vt.Selection.init(start_pin, end_pin, false);
                            screen.select(sel) catch {};
                        },
                        2 => {
                            const word_start = screen.selectWord(start_pin, &[_]u21{});
                            const word_end = screen.selectWord(end_pin, &[_]u21{});
                            if (word_start != null and word_end != null) {
                                const sel = if (end_pin.before(start_pin))
                                    ghostty_vt.Selection.init(word_end.?.start(), word_start.?.end(), false)
                                else
                                    ghostty_vt.Selection.init(word_start.?.start(), word_end.?.end(), false);
                                screen.select(sel) catch {};
                            }
                        },
                        3 => {
                            const line_start = screen.selectLine(.{ .pin = start_pin });
                            const line_end = screen.selectLine(.{ .pin = end_pin });
                            if (line_start != null and line_end != null) {
                                const sel = if (end_pin.before(start_pin))
                                    ghostty_vt.Selection.init(line_end.?.start(), line_start.?.end(), false)
                                else
                                    ghostty_vt.Selection.init(line_start.?.start(), line_end.?.end(), false);
                                screen.select(sel) catch {};
                            }
                        },
                        else => {},
                    }
                    _ = posix.write(pty_instance.pipe_fds[1], "x") catch {};
                }
            },
            .release => {
                pty_instance.selection_start = null;
            },
            .motion => {},
        }
    }

    /// Handle mouse report for sending to terminal.
    fn handleMouseReport(
        self: *Client,
        pty_instance: *Pty,
        mouse: key_parse.MouseEvent,
        terminal: mouse_encode.TerminalState,
    ) !void {
        _ = self;
        var encode_buf: [32]u8 = undefined;
        var writer = std.Io.Writer.fixed(&encode_buf);

        mouse_encode.encode(&writer, mouse, terminal) catch |err| {
            log.err("Failed to encode mouse: {}", .{err});
            return;
        };

        const encoded = writer.buffered();
        if (encoded.len > 0) {
            _ = posix.write(pty_instance.process.master, encoded) catch |err| {
                logPtyWriteError(err);
            };
        }
    }

    /// Resize PTY and update terminal dimensions.
    fn handleResizePty(self: *Client, notif: rpc.Notification) !void {
        if (notif.params != .array or notif.params.array.len < 3) {
            log.warn("resize_pty notification: invalid params", .{});
            return;
        }

        const pty_id = parsePtyId(notif.params.array[0]) orelse {
            log.warn("resize_pty notification: invalid pty_id type", .{});
            return;
        };
        const rows = parseU16(notif.params.array[1]) orelse {
            log.warn("resize_pty notification: invalid rows type", .{});
            return;
        };
        const cols = parseU16(notif.params.array[2]) orelse {
            log.warn("resize_pty notification: invalid cols type", .{});
            return;
        };

        var x_pixel: u16 = 0;
        var y_pixel: u16 = 0;
        if (notif.params.array.len >= 5) {
            x_pixel = parseU16(notif.params.array[3]) orelse 0;
            y_pixel = parseU16(notif.params.array[4]) orelse 0;
        }

        if (self.server.ptys.get(pty_id)) |pty_instance| {
            // Only the size owner's resize requests are applied
            if (pty_instance.size_owner != self) {
                log.info("resize_pty: ignoring from non-owner client {} for pty={}", .{ self.fd, pty_id });
                return;
            }

            pty_instance.terminal_mutex.lock();

            log.info("resize_pty: pty={} requested={}x{} ({}x{}px) current_terminal={}x{}", .{
                pty_id,                     cols,                       rows, x_pixel, y_pixel,
                pty_instance.terminal.cols, pty_instance.terminal.rows,
            });

            const size: pty.Winsize = .{
                .ws_row = rows,
                .ws_col = cols,
                .ws_xpixel = x_pixel,
                .ws_ypixel = y_pixel,
            };
            var pty_mut = pty_instance.process;
            pty_mut.setSize(size) catch |err| {
                log.err("Resize PTY failed: {}", .{err});
            };
            if (pty_instance.terminal.rows != rows or pty_instance.terminal.cols != cols) {
                log.info("resize_pty: resizing terminal from {}x{} to {}x{}", .{
                    pty_instance.terminal.cols,
                    pty_instance.terminal.rows,
                    cols,
                    rows,
                });
                pty_instance.terminal.resize(
                    pty_instance.allocator,
                    cols,
                    rows,
                ) catch |err| {
                    log.err("Resize terminal failed: {}", .{err});
                };
                pty_instance.terminal.screens.active.select(null) catch {};
            }
            // Update pixel dimensions for mouse encoding
            pty_instance.terminal.width_px = x_pixel;
            pty_instance.terminal.height_px = y_pixel;

            // Send in-band size report if mode 2048 is enabled
            const in_band_enabled = pty_instance.terminal.modes.get(.in_band_size_reports);
            log.info("resize_pty: in_band_size_reports mode={}", .{in_band_enabled});
            if (in_band_enabled) {
                var report_buf: [64]u8 = undefined;
                const report = std.fmt.bufPrint(&report_buf, "\x1b[48;{};{};{};{}t", .{
                    rows,
                    cols,
                    y_pixel,
                    x_pixel,
                }) catch unreachable;
                log.info("resize_pty: sending in-band report: {s}", .{report});
                _ = posix.write(pty_instance.process.master, report) catch |err| {
                    log.err("Failed to send in-band size report: {}", .{err});
                };
            }

            pty_instance.terminal_mutex.unlock();

            // Send full redraw to client so the resized terminal content is visible
            // immediately, without waiting for the child process to produce output
            const msg = buildRedrawMessageFromPty(self.server.allocator, pty_instance, .full) catch |err| {
                log.warn("resize_pty: failed to build redraw message: {}", .{err});
                return;
            };
            defer self.server.allocator.free(msg);

            self.server.sendRedraw(self.server.loop, pty_instance, msg, self) catch |err| {
                log.warn("resize_pty: failed to send redraw: {}", .{err});
            };

            log.info("resize_pty: completed for pty={}", .{pty_id});
        } else {
            log.warn("resize_pty notification: PTY {} not found", .{pty_id});
        }
    }

    /// Detach client from PTY.
    fn handleDetachPty(self: *Client, notif: rpc.Notification) !void {
        if (notif.params != .array or notif.params.array.len < 2) {
            log.warn("detach_pty notification: invalid params", .{});
            return;
        }

        const pty_id = parsePtyId(notif.params.array[0]) orelse {
            log.warn("detach_pty notification: invalid pty_id type", .{});
            return;
        };
        const client_fd = parseFd(notif.params.array[1]) orelse {
            log.warn("detach_pty notification: invalid client_fd type", .{});
            return;
        };

        if (self.server.ptys.get(pty_id)) |pty_instance| {
            for (self.server.clients.items) |c| {
                if (c.fd == client_fd) {
                    pty_instance.removeClient(c);
                    for (c.attached_ptys.items, 0..) |pid, i| {
                        if (pid == pty_id) {
                            _ = c.attached_ptys.swapRemove(i);
                            break;
                        }
                    }
                    log.info("Client {} detached from PTY {}", .{ c.fd, pty_id });
                    break;
                }
            }
        } else {
            log.warn("detach_pty notification: PTY {} not found", .{pty_id});
        }
    }

    /// Send focus in/out event to terminal.
    fn handleFocusEvent(self: *Client, notif: rpc.Notification) !void {
        if (notif.params != .array or notif.params.array.len < 2) {
            log.warn("focus_event notification: invalid params", .{});
            return;
        }

        const pty_id = parsePtyId(notif.params.array[0]) orelse {
            log.warn("focus_event notification: invalid pty_id type", .{});
            return;
        };
        const focused: bool = switch (notif.params.array[1]) {
            .boolean => |b| b,
            else => {
                log.warn("focus_event notification: invalid focused type", .{});
                return;
            },
        };

        if (self.server.ptys.get(pty_id)) |pty_instance| {
            pty_instance.terminal_mutex.lock();
            const focus_event_enabled = pty_instance.terminal.modes.get(.focus_event);
            pty_instance.terminal_mutex.unlock();

            if (focus_event_enabled) {
                const seq: []const u8 = if (focused) "\x1b[I" else "\x1b[O";
                _ = posix.write(pty_instance.process.master, seq) catch |err| {
                    log.err("Failed to write focus event to PTY: {}", .{err});
                };
                log.debug("Sent focus {} to PTY {}", .{ focused, pty_id });
            }
        } else {
            log.warn("focus_event notification: PTY {} not found", .{pty_id});
        }
    }

    /// Handle color_response notification from client.
    /// Formats and writes OSC color response to the PTY.
    fn handleColorResponse(self: *Client, notif: rpc.Notification) !void {
        if (notif.params != .map) {
            log.warn("color_response notification: invalid params (expected map)", .{});
            return;
        }

        var pty_id: ?usize = null;
        var r: ?u8 = null;
        var g: ?u8 = null;
        var b: ?u8 = null;
        var index: ?u8 = null;
        var kind: ?[]const u8 = null;
        var slot: ?usize = null;

        for (notif.params.map) |kv| {
            if (kv.key != .string) continue;
            if (std.mem.eql(u8, kv.key.string, "pty_id")) {
                pty_id = parsePtyId(kv.value);
            } else if (std.mem.eql(u8, kv.key.string, "r")) {
                r = parseU8(kv.value);
            } else if (std.mem.eql(u8, kv.key.string, "g")) {
                g = parseU8(kv.value);
            } else if (std.mem.eql(u8, kv.key.string, "b")) {
                b = parseU8(kv.value);
            } else if (std.mem.eql(u8, kv.key.string, "index")) {
                index = parseU8(kv.value);
            } else if (std.mem.eql(u8, kv.key.string, "kind")) {
                kind = if (kv.value == .string) kv.value.string else null;
            } else if (std.mem.eql(u8, kv.key.string, "slot")) {
                slot = parsePtyId(kv.value);
            }
        }

        const pid = pty_id orelse {
            log.warn("color_response: missing pty_id", .{});
            return;
        };
        const red = r orelse {
            log.warn("color_response: missing r", .{});
            return;
        };
        const green = g orelse {
            log.warn("color_response: missing g", .{});
            return;
        };
        const blue = b orelse {
            log.warn("color_response: missing b", .{});
            return;
        };
        const response_slot = slot orelse {
            log.warn("color_response: missing slot", .{});
            return;
        };

        const pty_instance = self.server.ptys.get(pid) orelse {
            log.warn("color_response: PTY {} not found", .{pid});
            return;
        };

        // Format OSC response: rgb:RRRR/GGGG/BBBB (16-bit scaled)
        // Scale 8-bit to 16-bit by duplicating: 0xAB -> 0xABAB
        const r16 = @as(u16, red) * 0x101;
        const g16 = @as(u16, green) * 0x101;
        const b16 = @as(u16, blue) * 0x101;

        var buf: [64]u8 = undefined;
        const response: []const u8 = if (index) |idx|
            // OSC 4 response: \x1b]4;INDEX;rgb:RRRR/GGGG/BBBB\x1b\\
            std.fmt.bufPrint(&buf, "\x1b]4;{};rgb:{x:0>4}/{x:0>4}/{x:0>4}\x1b\\", .{ idx, r16, g16, b16 }) catch return
        else if (kind) |k|
            // OSC 10/11/12 response
            if (std.mem.eql(u8, k, "foreground"))
                std.fmt.bufPrint(&buf, "\x1b]10;rgb:{x:0>4}/{x:0>4}/{x:0>4}\x1b\\", .{ r16, g16, b16 }) catch return
            else if (std.mem.eql(u8, k, "background"))
                std.fmt.bufPrint(&buf, "\x1b]11;rgb:{x:0>4}/{x:0>4}/{x:0>4}\x1b\\", .{ r16, g16, b16 }) catch return
            else if (std.mem.eql(u8, k, "cursor"))
                std.fmt.bufPrint(&buf, "\x1b]12;rgb:{x:0>4}/{x:0>4}/{x:0>4}\x1b\\", .{ r16, g16, b16 }) catch return
            else {
                log.warn("color_response: unknown kind '{s}'", .{k});
                return;
            }
        else {
            log.warn("color_response: missing index or kind", .{});
            return;
        };

        // Fill the response into its slot and try to flush
        pty_instance.fillColorResponse(response_slot, response);
        _ = pty_instance.flushResponses();

        log.debug("Filled color response slot {} for PTY {}: {s}", .{ response_slot, pid, response });
    }

    /// Receive a session_file_changed notification from a TUI client that
    /// just mutated another session's saved-state file (e.g. via
    /// placePtyInSession). Fan it out to every other TUI client so any
    /// client currently attached to the named session can reload from disk
    /// and avoid clobbering the mutation on its next save.
    fn handleSessionFileChanged(self: *Client, notif: rpc.Notification) !void {
        if (notif.params != .map) {
            log.warn("session_file_changed notification: invalid params (expected map)", .{});
            return;
        }

        var session_name: ?[]const u8 = null;
        for (notif.params.map) |kv| {
            if (kv.key != .string) continue;
            if (std.mem.eql(u8, kv.key.string, "session_name")) {
                if (kv.value == .string) session_name = kv.value.string;
            }
        }

        const name = session_name orelse {
            log.warn("session_file_changed: missing session_name", .{});
            return;
        };

        try self.server.broadcastSessionFileChanged(self.server.loop, name);
    }

    /// Parse u8 from msgpack value, returns null if invalid type.
    fn parseU8(val: msgpack.Value) ?u8 {
        return switch (val) {
            .unsigned => |u| if (u <= 255) @intCast(u) else null,
            .integer => |i| if (i >= 0 and i <= 255) @intCast(i) else null,
            else => null,
        };
    }

    /// Parse PTY ID from msgpack value, returns null if invalid type.
    fn parsePtyId(val: msgpack.Value) ?usize {
        return switch (val) {
            .unsigned => |u| @intCast(u),
            .integer => |i| @intCast(i),
            else => null,
        };
    }

    /// Parse u16 from msgpack value, returns null if invalid type.
    fn parseU16(val: msgpack.Value) ?u16 {
        return switch (val) {
            .unsigned => |u| @intCast(u),
            .integer => |i| @intCast(i),
            else => null,
        };
    }

    /// Parse file descriptor from msgpack value, returns null if invalid type.
    fn parseFd(val: msgpack.Value) ?posix.fd_t {
        return switch (val) {
            .unsigned => |u| @intCast(u),
            .integer => |i| @intCast(i),
            else => null,
        };
    }

    /// Parse input data (string or binary) from msgpack value, returns null if invalid type.
    fn parseInputData(val: msgpack.Value) ?[]const u8 {
        return switch (val) {
            .binary => |b| b,
            .string => |s| s,
            else => null,
        };
    }

    fn onRecv(loop: *io.Loop, completion: io.Completion) anyerror!void {
        const client = completion.userdataCast(Client);
        const allocator = client.server.allocator;

        switch (completion.result) {
            .recv => |bytes_read| {
                if (bytes_read == 0) {
                    // EOF - client disconnected
                    log.debug("Client fd={} disconnected (EOF)", .{client.fd});
                    client.server.removeClient(client);
                    return;
                }

                // Accumulate received data
                client.msg_buffer.appendSlice(allocator, client.recv_buffer[0..bytes_read]) catch |err| {
                    log.err("Failed to append to msg_buffer: {}", .{err});
                    client.server.removeClient(client);
                    return;
                };

                // Process all complete messages in the buffer
                while (client.msg_buffer.items.len > 0) {
                    const result = rpc.decodeMessageWithSize(allocator, client.msg_buffer.items) catch |err| {
                        if (err == error.EndOfStream or err == error.UnexpectedEndOfInput) {
                            // Incomplete message, wait for more data
                            break;
                        }
                        log.err("Failed to decode message: {}", .{err});
                        client.server.removeClient(client);
                        return;
                    };
                    defer result.message.deinit(allocator);

                    client.processMessage(loop, result.message) catch |err| {
                        log.err("Failed to process message: {}", .{err});
                    };

                    // Remove consumed bytes from buffer
                    const remaining = client.msg_buffer.items.len - result.bytes_consumed;
                    if (remaining > 0) {
                        std.mem.copyForwards(u8, client.msg_buffer.items[0..remaining], client.msg_buffer.items[result.bytes_consumed..]);
                    }
                    client.msg_buffer.shrinkRetainingCapacity(remaining);
                }

                // Keep receiving
                _ = try loop.recv(client.fd, &client.recv_buffer, .{
                    .ptr = client,
                    .cb = onRecv,
                });
            },
            .err => {
                log.debug("Client fd={} disconnected (error)", .{client.fd});
                client.server.removeClient(client);
            },
            else => unreachable,
        }
    }
};

const Server = struct {
    allocator: std.mem.Allocator,
    loop: *io.Loop,
    listen_fd: posix.fd_t,
    socket_path: []const u8,
    clients: std.ArrayList(*Client),
    ptys: std.AutoHashMap(usize, *Pty),
    next_pty_id: usize = 0,
    /// Monotonic per-process-lifetime counter for `Client.id`. Bumped at
    /// accept-time. Two consumers:
    ///   1. Plug lifecycle events: id is exposed to plugs via the
    ///      client_connected / client_disconnected notifications.
    ///   2. The deterministic broker-pick key for the client-broker RPC
    ///      pattern (lowest id among attached clients drives e.g.
    ///      break_pane). Resets on server restart. Starts at 1 so 0 can
    ///      encode "unknown client" in payloads if ever needed.
    next_client_id: usize = 1,
    /// In-flight client-broker RPC requests, keyed by request_id.
    /// Capped at `LIMITS.PENDING_MAX`. Entries are dropped when the
    /// broker replies, when the deadline-sweep timer expires the
    /// request, or when either end disconnects.
    pending: std.AutoHashMap(usize, PendingBreak),
    /// Monotonic counter for the broker-RPC `request_id` field. Lives
    /// in the notification payload (NOT the msgpack-RPC msgid) to
    /// correlate the broker's reply back to the originating CLI.
    next_request_id: usize = 0,
    /// Handle on the re-arming deadline-sweep timer. `null` until the
    /// first pending entry triggers timer arm; reset to `null` in the
    /// timer callback before re-arming.
    pending_sweep_timer: ?io.Task = null,
    accepting: bool = true,
    accept_task: ?io.Task = null,
    exit_on_idle: bool = false,
    signal_pipe_fds: [2]posix.fd_t,
    signal_buf: [1]u8 = undefined,
    /// Timestamp (ms since epoch) when server started - used to detect server restarts
    start_time_ms: i64 = 0,
    /// Registered plug processes, keyed by plug name.
    /// Default uses undefined allocator — startServer sets it properly.
    plugs: std.StringHashMap(*Client) = std.StringHashMap(*Client).init(undefined),
    /// Plug processes spawned by the server via spawn_plug.
    managed_plugs: std.ArrayList(ManagedPlug) = std.ArrayList(ManagedPlug).empty,
    /// In-flight call_plug requests, keyed by the forward msgid sent to the plug.
    pending_forwards: std.AutoHashMap(u32, PendingForward),
    /// Next msgid to use when forwarding requests to plugs.
    next_forward_msgid: u32 = 1,
    /// Heap context for the sweep timer — freed on shutdown.
    sweep_timer_ctx: ?*SweepTimerContext = null,
    /// Active sweep timer task — cancelled on shutdown to prevent use-after-free.
    sweep_timer_task: ?io.Task = null,
    /// Set true during shutdown to gate restart timer callbacks.
    shutting_down: bool = false,

    const ParsedSpawnPty = struct {
        size: pty.Winsize,
        attach: bool,
        cwd: ?[]const u8,
        env: ?[]const msgpack.Value,
        macos_option_as_alt: key_encode.OptionAsAlt,
        cmd: ?[]const u8,
        argv: ?[]const msgpack.Value,
        session: ?[]const u8,
        tab: ?[]const u8,
        title: ?[]const u8,
        /// When set, the new PTY is placed as a split sibling of the pane
        /// with this pty_id rather than as a new tab. Used by callers that
        /// want a stacked or side-by-side layout in detached mode (e.g.
        /// `prisectl start-arthack` building a single dash tab with two
        /// panes). When null, behavior matches the original append-tab path.
        split_target_pty_id: ?usize,
        /// Layout direction for the new split node. "col" stacks panes
        /// vertically (top/bottom), "row" places them side-by-side (left/
        /// right). Mirrors the in-memory `tiling.lua` direction tokens
        /// (split_vertical → "col", split_horizontal → "row").
        split_direction: SplitDirection,
        /// Initial ratio of the new split node. Honored by the layout
        /// renderer (`tiling.lua:render_node`); 0.5 is an even split.
        split_ratio: f64,
        focus: ?bool = null,
    };

    const SplitDirection = enum {
        col,
        row,

        fn toString(self: SplitDirection) []const u8 {
            return switch (self) {
                .col => "col",
                .row => "row",
            };
        }
    };

    fn parseSpawnPtyParams(params: msgpack.Value) ParsedSpawnPty {
        var rows: u16 = 24;
        var cols: u16 = 80;
        var attach: bool = false;
        var cwd: ?[]const u8 = null;
        var env: ?[]const msgpack.Value = null;
        var macos_option_as_alt: key_encode.OptionAsAlt = .false;
        var cmd: ?[]const u8 = null;
        var argv: ?[]const msgpack.Value = null;
        var session: ?[]const u8 = null;
        var tab: ?[]const u8 = null;
        var title: ?[]const u8 = null;
        var split_target_pty_id: ?usize = null;
        var split_direction: SplitDirection = .col;
        var split_ratio: f64 = 0.5;
        var focus: ?bool = null;

        if (params == .map) {
            for (params.map) |kv| {
                if (kv.key != .string) continue;
                if (std.mem.eql(u8, kv.key.string, "rows") and kv.value == .unsigned) {
                    rows = @intCast(kv.value.unsigned);
                } else if (std.mem.eql(u8, kv.key.string, "cols") and kv.value == .unsigned) {
                    cols = @intCast(kv.value.unsigned);
                } else if (std.mem.eql(u8, kv.key.string, "attach") and kv.value == .boolean) {
                    attach = kv.value.boolean;
                } else if (std.mem.eql(u8, kv.key.string, "cwd") and kv.value == .string) {
                    cwd = kv.value.string;
                } else if (std.mem.eql(u8, kv.key.string, "env") and kv.value == .array) {
                    env = kv.value.array;
                } else if (std.mem.eql(u8, kv.key.string, "macos_option_as_alt")) {
                    macos_option_as_alt = parseMacosOptionAsAlt(kv.value);
                } else if (std.mem.eql(u8, kv.key.string, "cmd") and kv.value == .string) {
                    cmd = kv.value.string;
                } else if (std.mem.eql(u8, kv.key.string, "argv") and kv.value == .array) {
                    argv = kv.value.array;
                } else if (std.mem.eql(u8, kv.key.string, "session") and kv.value == .string) {
                    session = kv.value.string;
                } else if (std.mem.eql(u8, kv.key.string, "tab") and kv.value == .string) {
                    tab = kv.value.string;
                } else if (std.mem.eql(u8, kv.key.string, "title") and kv.value == .string) {
                    title = kv.value.string;
                } else if (std.mem.eql(u8, kv.key.string, "split_target_pty_id")) {
                    // Accept both .unsigned (msgpack uint) and .integer
                    // (msgpack signed int). Negative or wrong-type values
                    // leave split_target_pty_id null, matching the
                    // "missing field" path — callers that supply garbage
                    // will fall through to append-tab semantics rather
                    // than failing the RPC, mirroring how cmd/cwd/title
                    // parse errors are silently dropped.
                    if (kv.value == .unsigned) {
                        split_target_pty_id = @intCast(kv.value.unsigned);
                    } else if (kv.value == .integer and kv.value.integer >= 0) {
                        split_target_pty_id = @intCast(kv.value.integer);
                    }
                } else if (std.mem.eql(u8, kv.key.string, "split_direction") and kv.value == .string) {
                    if (std.mem.eql(u8, kv.value.string, "row")) {
                        split_direction = .row;
                    } else if (std.mem.eql(u8, kv.value.string, "col")) {
                        split_direction = .col;
                    }
                } else if (std.mem.eql(u8, kv.key.string, "split_ratio")) {
                    // Accept .float for the canonical msgpack float type;
                    // also accept .unsigned/.integer (e.g. ratio = 1) so a
                    // caller passing an int doesn't silently get the
                    // default 0.5.
                    if (kv.value == .float) {
                        split_ratio = kv.value.float;
                    } else if (kv.value == .unsigned) {
                        split_ratio = @floatFromInt(kv.value.unsigned);
                    } else if (kv.value == .integer) {
                        split_ratio = @floatFromInt(kv.value.integer);
                    }
                } else if (std.mem.eql(u8, kv.key.string, "focus") and kv.value == .boolean) {
                    focus = kv.value.boolean;
                }
            }
        }

        return .{
            .size = .{
                .ws_row = rows,
                .ws_col = cols,
                .ws_xpixel = 0,
                .ws_ypixel = 0,
            },
            .attach = attach,
            .cwd = cwd,
            .env = env,
            .macos_option_as_alt = macos_option_as_alt,
            .cmd = cmd,
            .argv = argv,
            .session = session,
            .tab = tab,
            .title = title,
            .split_target_pty_id = split_target_pty_id,
            .split_direction = split_direction,
            .split_ratio = split_ratio,
            .focus = focus,
        };
    }

    fn prepareSpawnEnv(allocator: std.mem.Allocator, env_map: *std.process.EnvMap) !std.ArrayList([]const u8) {
        try env_map.put("TERM", "xterm-256color");
        try env_map.put("COLORTERM", "truecolor");

        var env_list = std.ArrayList([]const u8).empty;
        var it = env_map.iterator();
        while (it.next()) |entry| {
            const key_eq_val = try std.fmt.allocPrint(allocator, "{s}={s}", .{ entry.key_ptr.*, entry.value_ptr.* });
            try env_list.append(allocator, key_eq_val);
        }
        return env_list;
    }

    fn appendPriseSpawnEnv(self: *Server, env_list: *std.ArrayList([]const u8), pty_id: usize) !void {
        const prise_str = try self.allocator.dupe(u8, "PRISE=1");
        try env_list.append(self.allocator, prise_str);

        var pty_id_env_buf: [32]u8 = undefined;
        const pty_id_env = try std.fmt.bufPrint(&pty_id_env_buf, "PRISE_PTY={d}", .{pty_id});
        const prise_pty_str = try self.allocator.dupe(u8, pty_id_env);
        try env_list.append(self.allocator, prise_pty_str);

        var pty_validity_env_buf: [48]u8 = undefined;
        const pty_validity_env = try std.fmt.bufPrint(&pty_validity_env_buf, "PRISE_PTY_VALIDITY={d}", .{self.start_time_ms});
        const prise_pty_validity_str = try self.allocator.dupe(u8, pty_validity_env);
        try env_list.append(self.allocator, prise_pty_validity_str);

        var socket_env_buf: [280]u8 = undefined;
        const socket_env = try std.fmt.bufPrint(&socket_env_buf, "PRISE_SOCKET={s}", .{self.socket_path});
        const prise_socket_str = try self.allocator.dupe(u8, socket_env);
        try env_list.append(self.allocator, prise_socket_str);
    }

    fn parseClosePtyParams(params: msgpack.Value) !usize {
        return parsePtyId(params);
    }

    /// Parse `break_pane` request params from a msgpack map.
    ///
    /// Wire shape: `{pty_id: u32, focus: bool}` — both fields required.
    /// `pty_id` accepts the full u32 range; `focus` must be a boolean.
    ///
    /// Returns `error.MalformedParams` on missing fields or wrong types
    /// — same error name the CLI's wire-shape test expects, surfaced
    /// back to the originating client via `sendErrorResponse`.
    fn parseBreakPaneParams(params: msgpack.Value) !struct { pty_id: u32, focus: bool } {
        if (params != .map) return error.MalformedParams;

        var have_pty_id = false;
        var have_focus = false;
        var pty_id: u32 = 0;
        var focus: bool = false;

        for (params.map) |kv| {
            if (kv.key != .string) continue;
            if (std.mem.eql(u8, kv.key.string, "pty_id")) {
                pty_id = switch (kv.value) {
                    .unsigned => |u| std.math.cast(u32, u) orelse return error.MalformedParams,
                    .integer => |i| std.math.cast(u32, i) orelse return error.MalformedParams,
                    else => return error.MalformedParams,
                };
                have_pty_id = true;
            } else if (std.mem.eql(u8, kv.key.string, "focus")) {
                if (kv.value != .boolean) return error.MalformedParams;
                focus = kv.value.boolean;
                have_focus = true;
            }
        }

        if (!have_pty_id or !have_focus) return error.MalformedParams;

        return .{ .pty_id = pty_id, .focus = focus };
    }

    fn parseAttachPtyParams(params: msgpack.Value) !struct { pty_id: usize, macos_option_as_alt: key_encode.OptionAsAlt } {
        const pty_id = try parsePtyId(params);
        const macos_option_as_alt = if (params == .array and params.array.len >= 2)
            parseMacosOptionAsAlt(params.array[1])
        else
            .false;
        return .{ .pty_id = pty_id, .macos_option_as_alt = macos_option_as_alt };
    }

    fn parsePtyId(params: msgpack.Value) !usize {
        if (params != .array or params.array.len < 1) {
            return error.InvalidParams;
        }
        return switch (params.array[0]) {
            .unsigned => |u| @intCast(u),
            .integer => |i| @intCast(i),
            else => error.InvalidParams,
        };
    }

    fn parseMacosOptionAsAlt(value: msgpack.Value) key_encode.OptionAsAlt {
        if (value == .string) {
            if (std.mem.eql(u8, value.string, "left")) {
                return .left;
            } else if (std.mem.eql(u8, value.string, "right")) {
                return .right;
            } else if (std.mem.eql(u8, value.string, "true")) {
                return .true;
            }
        } else if (value == .boolean and value.boolean) {
            return .true;
        }
        return .false;
    }

    fn parseWritePtyParams(params: msgpack.Value) !struct { id: usize, data: []const u8 } {
        if (params != .array or params.array.len < 2 or params.array[0] != .unsigned or params.array[1] != .binary) {
            return error.InvalidParams;
        }
        return .{
            .id = @intCast(params.array[0].unsigned),
            .data = params.array[1].binary,
        };
    }

    const RenameTabParams = struct {
        pty_id: usize,
        title: []const u8,
        pty_validity: i64,
    };

    fn parseRenameTabParams(params: msgpack.Value) !RenameTabParams {
        if (params != .map) return error.InvalidParams;

        var pty_id: ?usize = null;
        var title: ?[]const u8 = null;
        var pty_validity: ?i64 = null;

        for (params.map) |kv| {
            if (kv.key != .string) continue;
            if (std.mem.eql(u8, kv.key.string, "pty_id")) {
                pty_id = switch (kv.value) {
                    .integer => |i| @intCast(i),
                    .unsigned => |u| @intCast(u),
                    else => return error.InvalidParams,
                };
            } else if (std.mem.eql(u8, kv.key.string, "title")) {
                title = switch (kv.value) {
                    .string => |value| value,
                    else => return error.InvalidParams,
                };
            } else if (std.mem.eql(u8, kv.key.string, "pty_validity")) {
                pty_validity = switch (kv.value) {
                    .integer => |value| value,
                    .unsigned => |value| @intCast(value),
                    else => return error.InvalidParams,
                };
            }
        }

        return .{
            .pty_id = pty_id orelse return error.MissingPtyId,
            .title = title orelse return error.MissingTitle,
            .pty_validity = pty_validity orelse return error.MissingPtyValidity,
        };
    }

    fn parseResizePtyParams(params: msgpack.Value) !struct { id: usize, rows: u16, cols: u16, x_pixel: u16, y_pixel: u16 } {
        if (params != .array or params.array.len < 3 or params.array[0] != .unsigned or params.array[1] != .unsigned or params.array[2] != .unsigned) {
            return error.InvalidParams;
        }

        var x_pixel: u16 = 0;
        var y_pixel: u16 = 0;

        if (params.array.len >= 5) {
            x_pixel = switch (params.array[3]) {
                .unsigned => |u| @intCast(u),
                .integer => |i| @intCast(i),
                else => 0,
            };
            y_pixel = switch (params.array[4]) {
                .unsigned => |u| @intCast(u),
                .integer => |i| @intCast(i),
                else => 0,
            };
        }

        return .{
            .id = @intCast(params.array[0].unsigned),
            .rows = @intCast(params.array[1].unsigned),
            .cols = @intCast(params.array[2].unsigned),
            .x_pixel = x_pixel,
            .y_pixel = y_pixel,
        };
    }

    fn handleSpawnPty(self: *Server, client: *Client, params: msgpack.Value) !msgpack.Value {
        if (self.ptys.count() >= LIMITS.PTYS_MAX) {
            log.warn("PTY limit reached ({})", .{LIMITS.PTYS_MAX});
            return msgpack.Value{ .string = try self.allocator.dupe(u8, "PTY limit reached") };
        }

        const parsed = parseSpawnPtyParams(params);
        const cwd = parsed.cwd orelse posix.getenv("HOME");
        log.info("spawn_pty: rows={} cols={} attach={} cwd={?s} has_client_env={}", .{ parsed.size.ws_row, parsed.size.ws_col, parsed.attach, cwd, parsed.env != null });

        var shell: []const u8 = "/bin/sh";
        var env_list = std.ArrayList([]const u8).empty;
        defer {
            for (env_list.items) |item| {
                self.allocator.free(item);
            }
            env_list.deinit(self.allocator);
        }

        if (parsed.env) |client_env| {
            for (client_env) |val| {
                if (val == .string) {
                    const env_str = try self.allocator.dupe(u8, val.string);
                    try env_list.append(self.allocator, env_str);
                    if (std.mem.startsWith(u8, val.string, "SHELL=")) {
                        shell = env_str[6..];
                    }
                }
            }
            const term_str = try self.allocator.dupe(u8, "TERM=xterm-256color");
            try env_list.append(self.allocator, term_str);
            const colorterm_str = try self.allocator.dupe(u8, "COLORTERM=truecolor");
            try env_list.append(self.allocator, colorterm_str);
        } else {
            var env_map = try std.process.getEnvMap(self.allocator);
            defer env_map.deinit();
            const prepared = try prepareSpawnEnv(self.allocator, &env_map);
            env_list = prepared;
            if (posix.getenv("SHELL")) |s| {
                shell = s;
            }
        }

        // argv, when present, bypasses the login shell entirely and execs
        // directly in the PTY child. This eliminates the visible shell-prompt
        // flash that occurs with the cmd path, which must first spawn the
        // shell, source rc files, and paint a prompt before the cmd bytes
        // are written at spawn time. cmd and argv are mutually exclusive
        // from the caller's perspective; argv takes precedence here.
        var argv_buf: [LIMITS.SPAWN_ARGV_MAX][]const u8 = undefined;
        var argv_slice: []const []const u8 = &.{shell};
        if (parsed.argv) |raw_argv| {
            if (raw_argv.len == 0) return error.InvalidParams;
            if (raw_argv.len > LIMITS.SPAWN_ARGV_MAX) return error.InvalidParams;
            for (raw_argv, 0..) |v, i| {
                if (v != .string) return error.InvalidParams;
                argv_buf[i] = v.string;
            }
            argv_slice = argv_buf[0..raw_argv.len];
        }

        // Assign PTY ID before spawn so we can set env vars (PRISE_PTY etc.)
        const pty_id = self.next_pty_id;
        self.next_pty_id += 1;

        try self.appendPriseSpawnEnv(&env_list, pty_id);

        const process = try pty.Process.spawn(self.allocator, parsed.size, argv_slice, @ptrCast(env_list.items), cwd);

        const pty_instance = try Pty.init(self.allocator, pty_id, process, parsed.size);
        pty_instance.server_ptr = self;

        try self.ptys.put(pty_id, pty_instance);
        std.debug.assert(self.ptys.count() <= LIMITS.PTYS_MAX);

        pty_instance.read_thread = try std.Thread.spawn(.{}, Pty.readThread, .{ pty_instance, self });

        _ = try self.loop.read(pty_instance.pipe_fds[0], &pty_instance.dirty_signal_buf, .{
            .ptr = pty_instance,
            .cb = onPtyDirty,
        });

        if (parsed.attach) {
            client.macos_option_as_alt = parsed.macos_option_as_alt;
            const newly_attached = try pty_instance.addClient(self.allocator, client);
            if (newly_attached) {
                try client.attached_ptys.append(self.allocator, pty_id);
            }

            log.info("Sending initial redraw for PTY {}", .{pty_id});
            const msg = try buildRedrawMessageFromPty(self.allocator, pty_instance, .full);
            defer self.allocator.free(msg);
            try self.sendRedraw(self.loop, pty_instance, msg, client);
        }

        // Write initial command to PTY if specified. Skipped in argv mode:
        // the target program is already running as the PTY child, so writing
        // a shell command would be fed to it as stdin instead of executed.
        if (parsed.argv == null) {
            if (parsed.cmd) |cmd| {
                log.info("Writing initial command to PTY {}: {s}", .{ pty_id, cmd });
                const cmd_with_newline = try std.fmt.allocPrint(self.allocator, "{s}\n", .{cmd});
                defer self.allocator.free(cmd_with_newline);

                var total_written: usize = 0;
                while (total_written < cmd_with_newline.len) {
                    const written = posix.write(process.master, cmd_with_newline[total_written..]) catch |err| {
                        log.warn("Failed to write initial command to PTY {}: {}", .{ pty_id, err });
                        break;
                    };
                    total_written += written;
                }
            }
        }

        log.info("Created PTY {} with PID {}", .{ pty_id, process.pid });
        crash_context.record("spawn pty_id={d}", .{pty_id});

        // Send pty_spawned notification to all clients
        try self.sendPtySpawned(pty_id, cwd orelse "", parsed.session, parsed.tab, parsed.title, parsed.focus);

        // Always persist to the session file when a target session is specified.
        // If a TUI client handles pty_spawned via Lua, it overwrites the file
        // on exit with its own state. If no TUI is connected, this is the only
        // record — the PTY will be discovered on next attach.
        if (parsed.session) |session_name| {
            const tab_title = parsed.tab orelse parsed.title;
            const split_spec: ?SplitSpec = if (parsed.split_target_pty_id) |target| .{
                .target_pty_id = target,
                .direction = parsed.split_direction,
                .ratio = parsed.split_ratio,
            } else null;
            self.placePtyInSessionFile(session_name, pty_id, cwd orelse "", tab_title, split_spec) catch |err| {
                log.warn("Failed to place PTY {} in session file '{s}': {}", .{ pty_id, session_name, err });
            };
        }

        return msgpack.Value{ .unsigned = pty_id };
    }

    fn handleClosePty(self: *Server, params: msgpack.Value) !msgpack.Value {
        const pty_id = parseClosePtyParams(params) catch {
            return msgpack.Value{ .string = try self.allocator.dupe(u8, "invalid params") };
        };

        if (self.ptys.get(pty_id)) |pty_instance| {
            // Signal read thread to exit - it will handle killing and reaping the process
            pty_instance.running.store(false, .seq_cst);
            _ = posix.write(pty_instance.exit_pipe_fds[1], "q") catch {};

            log.info("Signaled PTY {} to close", .{pty_id});
            return msgpack.Value.nil;
        } else {
            return msgpack.Value{ .string = try self.allocator.dupe(u8, "PTY not found") };
        }
    }

    /// Parse a `break_pane_reply` notification payload. The broker
    /// must include `request_id` (correlator), `ok` (success flag),
    /// and optionally `reason` (refusal-token string when ok=false).
    /// Returns `error.MalformedParams` on missing/wrong-type required
    /// fields. `reason` defaults to null when absent.
    fn parseBreakPaneReplyParams(params: msgpack.Value) !struct { request_id: usize, ok: bool, reason: ?[]const u8 } {
        if (params != .map) return error.MalformedParams;

        var have_request_id = false;
        var have_ok = false;
        var request_id: usize = 0;
        var ok: bool = false;
        var reason: ?[]const u8 = null;

        for (params.map) |kv| {
            if (kv.key != .string) continue;
            if (std.mem.eql(u8, kv.key.string, "request_id")) {
                request_id = switch (kv.value) {
                    .unsigned => |u| @intCast(u),
                    .integer => |i| std.math.cast(usize, i) orelse return error.MalformedParams,
                    else => return error.MalformedParams,
                };
                have_request_id = true;
            } else if (std.mem.eql(u8, kv.key.string, "ok")) {
                if (kv.value != .boolean) return error.MalformedParams;
                ok = kv.value.boolean;
                have_ok = true;
            } else if (std.mem.eql(u8, kv.key.string, "reason")) {
                if (kv.value == .string) {
                    reason = kv.value.string;
                }
            }
        }

        if (!have_request_id or !have_ok) return error.MalformedParams;

        return .{ .request_id = request_id, .ok = ok, .reason = reason };
    }

    /// Handle a `break_pane_reply` Notification from the broker.
    ///
    /// Looks up the pending entry by `request_id`. On match: drop the
    /// entry, send the matching Response back to the originating CLI,
    /// and (on `ok=true`) fan out a `break_pane_applied` broadcast to
    /// converge non-broker clients (broadcast helper lands in phase 8).
    /// Unknown `request_id` (timeout already fired, or never existed)
    /// is logged under the stable event name `rpc.broker.late_reply`
    /// and silently dropped — never a panic. Malformed payload is
    /// logged + dropped.
    ///
    /// Defense-in-depth: a buggy client could send `break_pane_reply`
    /// with a guessed `request_id` and either spoof `ok=true` (causing
    /// a bogus `break_pane_applied` broadcast) or race the legitimate
    /// broker. We require the dispatching client's id to match
    /// `entry.broker_id`; on mismatch we log under the stable event
    /// `rpc.broker.spoofed_reply` and leave the pending entry in place
    /// so the real broker (or the deadline sweep) can still resolve it.
    fn handleBreakPaneReply(self: *Server, self_client: *Client, notif: rpc.Notification) !void {
        const parsed = parseBreakPaneReplyParams(notif.params) catch |err| {
            log.warn("break_pane_reply: malformed payload: {}", .{err});
            return;
        };

        // Peek before removing: identity check must not consume the
        // pending entry on mismatch — the legitimate broker still
        // needs to resolve it.
        const peek = self.pending.get(parsed.request_id) orelse {
            log.info("event=\"rpc.broker.late_reply\" request_id={} ok={}", .{
                parsed.request_id,
                parsed.ok,
            });
            return;
        };

        if (peek.broker_id != self_client.id) {
            log.warn("event=\"rpc.broker.spoofed_reply\" request_id={} sender_id={} expected_broker_id={}", .{
                parsed.request_id,
                self_client.id,
                peek.broker_id,
            });
            return;
        }

        const entry = self.pending.fetchRemove(parsed.request_id).?;
        const cli_client = entry.value.cli_client;
        const cli_msgid = entry.value.cli_msgid;

        log.info("break_pane_reply: request_id={} ok={} reason={?s}", .{
            parsed.request_id,
            parsed.ok,
            parsed.reason,
        });

        // Reply to originating CLI BEFORE fanout — siblings can wait;
        // the CLI is blocked on this Response.
        try cli_client.sendBreakPaneResponse(self.loop, cli_msgid, parsed.ok, parsed.reason);

        // On ok=true, fan out `break_pane_applied` to non-broker
        // attached clients so their tile-tree mirrors converge. Best
        // effort: broadcast send errors do not roll back the CLI
        // Response (which has already been queued).
        if (parsed.ok) {
            self.sendBreakPaneApplied(
                entry.value.broker_id,
                entry.value.pty_id,
                entry.value.focus,
            ) catch |err| {
                log.warn("break_pane_reply: sendBreakPaneApplied failed: {}", .{err});
            };
        }
    }

    /// Handle the `break_pane` Request: pick a deterministic broker among
    /// attached clients, store a pending entry keyed by `request_id`, and
    /// notify the broker. The synchronous Response is sent only when we
    /// can refuse without consulting Lua (no attached clients, malformed
    /// params, or pending-table full); otherwise the eventual Response is
    /// emitted by `handleBreakPaneReply` when the broker fires its
    /// notification reply, by the deadline-sweep timer on timeout, or by
    /// `removeClient` if the broker disconnects.
    ///
    /// Owns its own response lifecycle — called from `handleRpcRequest`
    /// before the value-returning `handleRequest`. Returns an error only
    /// if the synchronous Response itself fails to send.
    fn handleBreakPane(self: *Server, client: *Client, msgid: u32, params: msgpack.Value) !void {
        const parsed = parseBreakPaneParams(params) catch |err| {
            log.warn("break_pane: malformed params: {}", .{err});
            return client.sendErrorResponse(self.loop, msgid, err);
        };

        // Broker-pick: lowest `Client.id` among clients with at least one
        // attached PTY. Empty result → synchronous `session_not_attached`
        // refusal (no point queueing for a possibly-never-attaching client).
        var broker: ?*Client = null;
        for (self.clients.items) |c| {
            if (c.attached_ptys.items.len == 0) continue;
            if (broker) |current| {
                if (c.id < current.id) broker = c;
            } else {
                broker = c;
            }
        }
        const broker_client = broker orelse {
            log.info("break_pane: no attached clients, refusing with session_not_attached", .{});
            return client.sendBreakPaneResponse(self.loop, msgid, false, "session_not_attached");
        };

        // Defensive cap. Single-user case never approaches PENDING_MAX;
        // a misbehaving caller hitting it gets the same UX as a slow
        // broker (broker_timeout) so the CLI exit-code map stays single-token.
        if (self.pending.count() >= LIMITS.PENDING_MAX) {
            log.warn("break_pane: pending table at limit ({}), refusing with broker_timeout", .{LIMITS.PENDING_MAX});
            return client.sendBreakPaneResponse(self.loop, msgid, false, "broker_timeout");
        }

        const request_id = self.next_request_id;
        self.next_request_id += 1;

        const deadline_ts = std.time.milliTimestamp() + LIMITS.PENDING_DEADLINE_MS;

        // Write pending FIRST so a fast broker reply that arrives before
        // we return finds the entry.
        try self.pending.put(request_id, .{
            .cli_msgid = msgid,
            .cli_client = client,
            .broker_id = broker_client.id,
            .deadline_ts = deadline_ts,
            .pty_id = parsed.pty_id,
            .focus = parsed.focus,
        });

        log.info("break_pane: pty_id={} focus={} broker_id={} request_id={} deadline_ts={}", .{
            parsed.pty_id,
            parsed.focus,
            broker_client.id,
            request_id,
            deadline_ts,
        });

        // Emit the broker notification AFTER the pending entry is
        // written so a fast broker reply finds the entry. If the send
        // fails (e.g. SendQueueFull, BrokerNotFound from a race with
        // removeClient), drop the pending entry immediately and reply
        // `broker_timeout` synchronously rather than wait the full
        // 2s for the deadline-sweep timer.
        self.sendBreakPaneRequest(broker_client.id, parsed.pty_id, parsed.focus, request_id) catch |err| {
            log.warn("break_pane: sendBreakPaneRequest failed: {}, replying broker_timeout", .{err});
            _ = self.pending.remove(request_id);
            return client.sendBreakPaneResponse(self.loop, msgid, false, "broker_timeout");
        };
    }

    fn handleAttachPty(self: *Server, client: *Client, params: msgpack.Value) !msgpack.Value {
        log.info("attach_pty called with params: {}", .{params});
        const parsed = parseAttachPtyParams(params) catch |err| {
            log.warn("attach_pty: invalid params: {}", .{err});
            return error.InvalidParams;
        };

        log.info("attach_pty: pty_id={} client_fd={} macos_option_as_alt={}", .{ parsed.pty_id, client.fd, parsed.macos_option_as_alt });

        const pty_instance = self.ptys.get(parsed.pty_id) orelse {
            log.warn("attach_pty: PTY {} not found", .{parsed.pty_id});
            return error.PtyNotFound;
        };

        client.macos_option_as_alt = parsed.macos_option_as_alt;

        const newly_attached = try pty_instance.addClient(self.allocator, client);
        if (newly_attached) {
            try client.attached_ptys.append(self.allocator, parsed.pty_id);
            log.info("Client {} attached to PTY {}", .{ client.fd, parsed.pty_id });
            crash_context.record("attach pty_id={d} client_fd={d}", .{ parsed.pty_id, client.fd });
            self.forwardPtyClientEvent("pty_attach", client.id, parsed.pty_id);
        } else {
            log.info("Client {} attach_pty for PTY {} was no-op (already attached)", .{ client.fd, parsed.pty_id });
        }

        const msg = try buildRedrawMessageFromPty(self.allocator, pty_instance, .full);
        defer self.allocator.free(msg);

        try self.sendRedraw(self.loop, pty_instance, msg, client);

        // Snapshot cwd under the terminal mutex — the read thread mutates it.
        const cwd_copy = blk: {
            pty_instance.terminal_mutex.lock();
            defer pty_instance.terminal_mutex.unlock();
            break :blk try self.allocator.dupe(u8, pty_instance.cwd.items);
        };

        // Keys must be allocator-owned: handleRpcRequest defers
        // result.deinit which calls allocator.free on every Value.string,
        // including map keys. A literal "pty_id" / "cwd" sits in rodata
        // and freeing it bus-errors the server. Other RPC handlers in this
        // file follow the same dupe-keys convention (handleSpawnPty,
        // handleListPtys, etc.). Notification builders use literals and
        // are safe because their maps are encoded then thrown away
        // without going through Value.deinit.
        var entries = try self.allocator.alloc(msgpack.Value.KeyValue, 2);
        entries[0] = .{
            .key = .{ .string = try self.allocator.dupe(u8, "pty_id") },
            .value = .{ .unsigned = parsed.pty_id },
        };
        entries[1] = .{
            .key = .{ .string = try self.allocator.dupe(u8, "cwd") },
            .value = .{ .string = cwd_copy },
        };
        return msgpack.Value{ .map = entries };
    }

    fn handleWritePty(self: *Server, params: msgpack.Value) !msgpack.Value {
        const args = parseWritePtyParams(params) catch {
            return msgpack.Value{ .string = try self.allocator.dupe(u8, "invalid params") };
        };

        const pty_instance = self.ptys.get(args.id) orelse {
            return msgpack.Value{ .string = try self.allocator.dupe(u8, "PTY not found") };
        };

        _ = posix.write(pty_instance.process.master, args.data) catch |err| {
            logPtyWriteError(err);
            return msgpack.Value{ .string = try self.allocator.dupe(u8, "write failed") };
        };

        return msgpack.Value.nil;
    }

    fn handleResizePty(self: *Server, client: *Client, params: msgpack.Value) !msgpack.Value {
        const args = parseResizePtyParams(params) catch {
            return msgpack.Value{ .string = try self.allocator.dupe(u8, "invalid params") };
        };

        const pty_instance = self.ptys.get(args.id) orelse {
            return msgpack.Value{ .string = try self.allocator.dupe(u8, "PTY not found") };
        };

        // Only the size owner's resize requests are applied
        if (pty_instance.size_owner != client) {
            log.info("resize_pty request: ignoring from non-owner client {} for pty={}", .{ client.fd, args.id });
            return msgpack.Value.nil;
        }

        // Lock mutex before any terminal state access to avoid race with read thread
        pty_instance.terminal_mutex.lock();

        log.info("resize_pty request: pty={} requested={}x{} ({}x{}px) current={}x{}", .{
            args.id,
            args.cols,
            args.rows,
            args.x_pixel,
            args.y_pixel,
            pty_instance.terminal.cols,
            pty_instance.terminal.rows,
        });

        const size: pty.Winsize = .{
            .ws_row = args.rows,
            .ws_col = args.cols,
            .ws_xpixel = args.x_pixel,
            .ws_ypixel = args.y_pixel,
        };

        var pty_mut = pty_instance.process;
        pty_mut.setSize(size) catch |err| {
            log.err("Resize PTY failed: {}", .{err});
            pty_instance.terminal_mutex.unlock();
            return msgpack.Value{ .string = try self.allocator.dupe(u8, "resize failed") };
        };
        if (pty_instance.terminal.rows != args.rows or pty_instance.terminal.cols != args.cols) {
            log.info("resize_pty request: resizing terminal from {}x{} to {}x{}", .{
                pty_instance.terminal.cols,
                pty_instance.terminal.rows,
                args.cols,
                args.rows,
            });
            pty_instance.terminal.resize(pty_instance.allocator, args.cols, args.rows) catch |err| {
                log.err("Resize terminal failed: {}", .{err});
            };
        }

        pty_instance.terminal.width_px = args.x_pixel;
        pty_instance.terminal.height_px = args.y_pixel;

        const in_band_enabled = pty_instance.terminal.modes.get(.in_band_size_reports);
        log.info("resize_pty request: in_band_size_reports mode={}", .{in_band_enabled});
        if (in_band_enabled) {
            var report_buf: [64]u8 = undefined;
            const report = std.fmt.bufPrint(&report_buf, "\x1b[48;{};{};{};{}t", .{
                args.rows,
                args.cols,
                args.y_pixel,
                args.x_pixel,
            }) catch unreachable;
            log.info("resize_pty request: sending in-band report", .{});
            _ = posix.write(pty_instance.process.master, report) catch |err| {
                log.err("Failed to send in-band size report: {}", .{err});
            };
        }

        pty_instance.terminal_mutex.unlock();

        // Send full redraw to client so the resized terminal content is visible
        // immediately, without waiting for the child process to produce output
        const msg = buildRedrawMessageFromPty(self.allocator, pty_instance, .full) catch |err| {
            log.warn("resize_pty request: failed to build redraw message: {}", .{err});
            return msgpack.Value.nil;
        };
        defer self.allocator.free(msg);

        self.sendRedraw(self.loop, pty_instance, msg, client) catch |err| {
            log.warn("resize_pty request: failed to send redraw: {}", .{err});
        };

        log.info("Resized PTY {} to {}x{} ({}x{}px)", .{ args.id, args.cols, args.rows, args.x_pixel, args.y_pixel });
        return msgpack.Value.nil;
    }

    fn handleDetachPty(self: *Server, client: *Client, params: msgpack.Value) !msgpack.Value {
        const pty_id: usize = switch (params) {
            .unsigned => |u| u,
            .integer => |i| @intCast(i),
            .array => |arr| blk: {
                if (arr.len < 1) return msgpack.Value{ .string = try self.allocator.dupe(u8, "invalid params") };
                break :blk switch (arr[0]) {
                    .unsigned => |u| u,
                    .integer => |i| @intCast(i),
                    else => return msgpack.Value{ .string = try self.allocator.dupe(u8, "invalid params") },
                };
            },
            else => return msgpack.Value{ .string = try self.allocator.dupe(u8, "invalid params") },
        };

        const pty_instance = self.ptys.get(pty_id) orelse {
            return msgpack.Value{ .string = try self.allocator.dupe(u8, "PTY not found") };
        };

        pty_instance.removeClient(client);
        var was_attached = false;
        for (client.attached_ptys.items, 0..) |pid, i| {
            if (pid == pty_id) {
                _ = client.attached_ptys.swapRemove(i);
                was_attached = true;
                break;
            }
        }
        log.info("Client {} detached from PTY {}", .{ client.fd, pty_id });
        if (was_attached) {
            self.forwardPtyClientEvent("pty_detach", client.id, pty_id);
        }

        return msgpack.Value.nil;
    }

    fn handleDetachPtys(self: *Server, client: *Client, params: msgpack.Value) !msgpack.Value {
        const pty_ids = switch (params) {
            .array => |arr| arr,
            else => return msgpack.Value{ .string = try self.allocator.dupe(u8, "invalid params") },
        };

        for (pty_ids) |pty_id_val| {
            const pty_id: usize = switch (pty_id_val) {
                .unsigned => |u| u,
                .integer => |i| @intCast(i),
                else => continue,
            };

            if (self.ptys.get(pty_id)) |pty_instance| {
                pty_instance.removeClient(client);
                var was_attached = false;
                for (client.attached_ptys.items, 0..) |pid, i| {
                    if (pid == pty_id) {
                        _ = client.attached_ptys.swapRemove(i);
                        was_attached = true;
                        break;
                    }
                }
                std.log.info("Client {} detached from PTY {}", .{ client.fd, pty_id });
                if (was_attached) {
                    self.forwardPtyClientEvent("pty_detach", client.id, pty_id);
                }
            }
        }

        return msgpack.Value.nil;
    }

    fn handleGetSelection(self: *Server, params: msgpack.Value) !msgpack.Value {
        const pty_id = parsePtyId(params) catch {
            return msgpack.Value{ .string = try self.allocator.dupe(u8, "invalid params") };
        };

        const pty_instance = self.ptys.get(pty_id) orelse {
            return msgpack.Value{ .string = try self.allocator.dupe(u8, "PTY not found") };
        };

        pty_instance.terminal_mutex.lock();
        defer pty_instance.terminal_mutex.unlock();

        const screen = pty_instance.terminal.screens.active;
        const sel = screen.selection orelse {
            return msgpack.Value.nil;
        };

        const result_z = screen.selectionString(self.allocator, .{
            .sel = sel,
            .trim = true,
        }) catch |err| {
            std.log.err("Failed to get selection string: {}", .{err});
            return msgpack.Value.nil;
        };

        // selectionString returns a sentinel-terminated slice ([:0]const u8).
        // msgpack.Value stores plain []const u8 and later deinit() calls
        // allocator.free on that plain slice. If we pass result_z directly,
        // deinit will free len bytes instead of len+1, triggering allocator
        // size-mismatch crashes when copying selections.
        defer self.allocator.free(result_z);
        const result = self.allocator.dupe(u8, result_z) catch |err| {
            std.log.err("Failed to duplicate selection string: {}", .{err});
            return msgpack.Value.nil;
        };

        return msgpack.Value{ .string = result };
    }

    fn handleClearSelection(self: *Server, params: msgpack.Value) !msgpack.Value {
        const pty_id = parsePtyId(params) catch {
            return msgpack.Value{ .string = try self.allocator.dupe(u8, "invalid params") };
        };

        const pty_instance = self.ptys.get(pty_id) orelse {
            return msgpack.Value{ .string = try self.allocator.dupe(u8, "PTY not found") };
        };

        pty_instance.terminal_mutex.lock();
        const screen = pty_instance.terminal.screens.active;
        screen.select(null) catch {};
        pty_instance.terminal_mutex.unlock();

        _ = posix.write(pty_instance.pipe_fds[1], "x") catch {};

        return msgpack.Value.nil;
    }

    fn handleGetServerInfo(self: *Server) !msgpack.Value {
        const entries = try self.allocator.alloc(msgpack.Value.KeyValue, 2);
        @memset(entries, .{ .key = .nil, .value = .nil });
        errdefer {
            for (entries) |kv| {
                kv.key.deinit(self.allocator);
                kv.value.deinit(self.allocator);
            }
            self.allocator.free(entries);
        }

        entries[0].key = .{ .string = try self.allocator.dupe(u8, "version") };
        entries[0].value = .{ .string = try self.allocator.dupe(u8, main.version) };
        entries[1].key = .{ .string = try self.allocator.dupe(u8, "pty_validity") };
        entries[1].value = .{ .integer = self.start_time_ms };

        return .{ .map = entries };
    }

    fn handleListPtys(self: *Server) !msgpack.Value {
        const pty_count = self.ptys.count();
        const ptys_array = try self.allocator.alloc(msgpack.Value, pty_count);

        var i: usize = 0;
        var ptys_owned = true;
        errdefer {
            if (ptys_owned) {
                for (ptys_array[0..i]) |entry| entry.deinit(self.allocator);
                self.allocator.free(ptys_array);
            }
        }

        var iter = self.ptys.iterator();
        while (iter.next()) |entry| {
            ptys_array[i] = .{ .map = try buildPtyEntry(self.allocator, entry.value_ptr.*) };
            i += 1;
        }

        const result_entries = try self.allocator.alloc(msgpack.Value.KeyValue, 2);
        @memset(result_entries, .{ .key = .nil, .value = .nil });
        errdefer {
            for (result_entries) |kv| {
                kv.key.deinit(self.allocator);
                kv.value.deinit(self.allocator);
            }
            self.allocator.free(result_entries);
        }

        result_entries[0].key = .{ .string = try self.allocator.dupe(u8, "pty_validity") };
        result_entries[0].value = .{ .integer = self.start_time_ms };
        result_entries[1].key = .{ .string = try self.allocator.dupe(u8, "ptys") };
        result_entries[1].value = .{ .array = ptys_array };

        // Ownership of ptys_array transferred into result_entries[1].value.
        // Disable the outer errdefer so it won't double-free — the
        // result_entries errdefer frees the array recursively via .deinit
        // on the .array variant.
        ptys_owned = false;

        return .{ .map = result_entries };
    }

    /// Return information about all managed plugs.
    fn handleListPlugs(self: *Server) !msgpack.Value {
        const plug_count = self.managed_plugs.items.len;
        const plugs_array = try self.allocator.alloc(msgpack.Value, plug_count);

        var i: usize = 0;
        var plugs_owned = true;
        errdefer {
            if (plugs_owned) {
                for (plugs_array[0..i]) |entry| entry.deinit(self.allocator);
                self.allocator.free(plugs_array);
            }
        }

        for (self.managed_plugs.items) |mp| {
            plugs_array[i] = .{ .map = try buildPlugEntry(self.allocator, &mp) };
            i += 1;
        }

        const result_entries = try self.allocator.alloc(msgpack.Value.KeyValue, 1);
        @memset(result_entries, .{ .key = .nil, .value = .nil });
        errdefer {
            for (result_entries) |kv| {
                kv.key.deinit(self.allocator);
                kv.value.deinit(self.allocator);
            }
            self.allocator.free(result_entries);
        }

        result_entries[0].key = .{ .string = try self.allocator.dupe(u8, "plugs") };
        result_entries[0].value = .{ .array = plugs_array };
        plugs_owned = false;

        return .{ .map = result_entries };
    }

    fn handleRequest(self: *Server, client: *Client, method: []const u8, params: msgpack.Value) !msgpack.Value {
        // On the first non-register_plug RPC, send existing plug notifications
        // and announce the client to subscribed plugs. Both are deferred from
        // onAccept so plug clients don't emit spurious client_connected
        // events for themselves before the register_plug handshake lands.
        if (!client.notified_plugs and !std.mem.eql(u8, method, "register_plug")) {
            client.notified_plugs = true;
            self.notifyExistingPlugs(self.loop, client);
            self.forwardClientEvent("client_connected", client.id);
        }

        if (std.mem.eql(u8, method, "ping")) {
            return msgpack.Value{ .string = try self.allocator.dupe(u8, "pong") };
        } else if (std.mem.eql(u8, method, "get_server_info")) {
            return self.handleGetServerInfo();
        } else if (std.mem.eql(u8, method, "list_ptys")) {
            return self.handleListPtys();
        } else if (std.mem.eql(u8, method, "list_plugs")) {
            return self.handleListPlugs();
        } else if (std.mem.eql(u8, method, "spawn_pty")) {
            return self.handleSpawnPty(client, params);
        } else if (std.mem.eql(u8, method, "close_pty")) {
            return self.handleClosePty(params);
        } else if (std.mem.eql(u8, method, "attach_pty")) {
            return self.handleAttachPty(client, params);
        } else if (std.mem.eql(u8, method, "write_pty")) {
            return self.handleWritePty(params);
        } else if (std.mem.eql(u8, method, "resize_pty")) {
            return self.handleResizePty(client, params);
        } else if (std.mem.eql(u8, method, "detach_pty")) {
            return self.handleDetachPty(client, params);
        } else if (std.mem.eql(u8, method, "detach_ptys")) {
            return self.handleDetachPtys(client, params);
        } else if (std.mem.eql(u8, method, "get_selection")) {
            return self.handleGetSelection(params);
        } else if (std.mem.eql(u8, method, "clear_selection")) {
            return self.handleClearSelection(params);
        } else if (std.mem.eql(u8, method, "rename_tab")) {
            return self.handleRenameTab(client, params);
        } else if (std.mem.eql(u8, method, "session_switch")) {
            return try self.handleSessionSwitch(params);
        } else if (std.mem.eql(u8, method, "notify_plug")) {
            return self.handleNotifyPlug(params);
        } else if (std.mem.eql(u8, method, "notify_plug_client")) {
            return self.handleNotifyPlugClient(params);
        } else if (std.mem.eql(u8, method, "spawn_plug")) {
            return self.handleSpawnPlug(params);
        } else if (std.mem.eql(u8, method, "register_plug")) {
            return self.handleRegisterPlug(client, params);
        } else {
            return msgpack.Value{ .string = try self.allocator.dupe(u8, "unknown method") };
        }
    }

    /// Handle register_plug RPC from a spawned plug process.
    /// Params: {name: string, token: string, subscribe: [string...] (optional)}
    fn handleRegisterPlug(self: *Server, client: *Client, params: msgpack.Value) !msgpack.Value {
        if (params != .map) return error.InvalidParams;

        // Already registered
        if (client.plug_name != null) return error.AlreadyRegistered;

        var name: ?[]const u8 = null;
        var token_str: ?[]const u8 = null;
        var subscribe: ?[]const msgpack.Value = null;

        for (params.map) |kv| {
            if (kv.key != .string) continue;
            if (std.mem.eql(u8, kv.key.string, "name")) {
                name = if (kv.value == .string) kv.value.string else null;
            } else if (std.mem.eql(u8, kv.key.string, "token")) {
                token_str = if (kv.value == .string) kv.value.string else null;
            } else if (std.mem.eql(u8, kv.key.string, "subscribe")) {
                subscribe = if (kv.value == .array) kv.value.array else null;
            }
        }

        const plug_name = name orelse return error.MissingPlugName;

        // Validate token against the managed plug's stored token
        const plug_token = token_str orelse return error.MissingPlugToken;
        const mp = self.findManagedPlug(plug_name) orelse return error.PermissionDenied;
        if (plug_token.len != LIMITS.PLUG_TOKEN_HEX_LEN or
            !std.crypto.timing_safe.eql([LIMITS.PLUG_TOKEN_HEX_LEN]u8, plug_token[0..LIMITS.PLUG_TOKEN_HEX_LEN].*, mp.token))
        {
            return error.PermissionDenied;
        }

        if (plug_name.len == 0 or plug_name.len > LIMITS.PLUG_NAME_MAX) {
            return error.InvalidPlugName;
        }

        if (self.plugs.contains(plug_name)) {
            return error.DuplicatePlugName;
        }

        const owned_name = try self.allocator.dupe(u8, plug_name);
        errdefer self.allocator.free(owned_name);

        // Parse and dupe subscriptions
        var owned_subs: ?[]const []const u8 = null;
        if (subscribe) |sub_arr| {
            var subs = try self.allocator.alloc([]const u8, sub_arr.len);
            var i: usize = 0;
            errdefer {
                for (subs[0..i]) |s| self.allocator.free(s);
                self.allocator.free(subs);
            }
            for (sub_arr) |item| {
                if (item != .string) continue;
                subs[i] = try self.allocator.dupe(u8, item.string);
                i += 1;
            }
            // Shrink to actual count (some non-string items may have been skipped)
            if (i < subs.len) {
                subs = try self.allocator.realloc(subs, i);
            }
            owned_subs = subs;
        }
        errdefer if (owned_subs) |subs| {
            for (subs) |s| self.allocator.free(s);
            self.allocator.free(subs);
        };

        // Complete all fallible work before publishing to client fields,
        // otherwise finishClose would double-free on error.
        try self.plugs.put(owned_name, client);
        errdefer _ = self.plugs.remove(owned_name);

        const response = try self.allocator.dupe(u8, "ok");

        // All fallible work succeeded — publish to client (infallible)
        client.plug_name = owned_name;
        client.plug_subscriptions = owned_subs;

        // Mark the managed plug as registered (mp from findManagedPlug above)
        mp.registered = true;

        // Cancel any pending restart timer — the child registered before it fired.
        // Without this, a late-registering child (wrapper exits before child connects)
        // would race with the restart timer spawning a second process.
        if (mp.restart_timer_task) |*task| {
            task.cancel(self.loop) catch {};
            mp.restart_timer_task = null;
        }
        if (mp.restart_ctx) |ctx| {
            self.allocator.free(ctx.plug_name);
            self.allocator.destroy(ctx);
            mp.restart_ctx = null;
        }

        log.info("Plug '{s}' registered with {} subscriptions", .{
            owned_name,
            if (owned_subs) |s| s.len else 0,
        });

        self.broadcastPlugConnected(self.loop, owned_name);

        // Replay client_connected for every non-plug client already on the
        // server. The newly-registered plug sees the same event stream
        // whether the client existed before or after registration, so the
        // megaplug mirror doesn't need a separate "initial snapshot" path.
        if (client.isSubscribedPlug("client_connected")) {
            for (self.clients.items) |c| {
                if (c.plug_name != null) continue;
                if (c.closing) continue;
                if (c == client) continue;
                if (!c.notified_plugs) continue;
                self.sendClientConnectedTo(client, c.id);
            }
        }

        return msgpack.Value{ .string = response };
    }

    /// Send a single client_connected notification to one specific plug.
    /// Used by the register-time replay path so the new plug sees an event
    /// for every existing non-plug client without re-broadcasting.
    fn sendClientConnectedTo(self: *Server, plug_client: *Client, client_id: usize) void {
        var map_items = self.allocator.alloc(msgpack.Value.KeyValue, 1) catch |err| {
            log.err("Failed to alloc client_connected replay: {}", .{err});
            return;
        };
        defer self.allocator.free(map_items);
        map_items[0] = .{ .key = .{ .string = "client_id" }, .value = .{ .unsigned = client_id } };

        const params = msgpack.Value{ .map = map_items };
        const msg_bytes = msgpack.encode(self.allocator, .{ 2, "client_connected", params }) catch |err| {
            log.err("Failed to encode client_connected replay: {}", .{err});
            return;
        };
        defer self.allocator.free(msg_bytes);

        plug_client.sendData(self.loop, msg_bytes) catch |err| {
            log.err("Failed to replay client_connected to plug '{s}': {}", .{
                plug_client.plug_name orelse "unknown",
                err,
            });
        };
    }

    /// Send a plug_connected notification to a single client.
    fn sendPlugConnectedTo(self: *Server, loop: *io.Loop, client: *Client, plug_name: []const u8) void {
        var map_items = self.allocator.alloc(msgpack.Value.KeyValue, 1) catch |err| {
            log.err("Failed to alloc plug_connected for fd={}: {}", .{ client.fd, err });
            return;
        };
        defer self.allocator.free(map_items);
        map_items[0] = .{ .key = .{ .string = "plug" }, .value = .{ .string = plug_name } };

        const params = msgpack.Value{ .map = map_items };
        const msg_bytes = msgpack.encode(self.allocator, .{ 2, "plug_connected", params }) catch |err| {
            log.err("Failed to encode plug_connected for fd={}: {}", .{ client.fd, err });
            return;
        };
        defer self.allocator.free(msg_bytes);

        client.sendData(loop, msg_bytes) catch |err| {
            log.err("Failed to send plug_connected to client fd={}: {}", .{ client.fd, err });
        };
    }

    /// Notify all non-plug TUI clients that a plug has connected.
    /// Other subscribed plugs also receive the notification — a plug that
    /// subscribes to `plug_connected` / `plug_disconnected` can observe
    /// siblings joining and leaving without polling. The just-registered
    /// plug is excluded from the forward so it does not receive a
    /// plug_connected event describing itself (it already knows it
    /// just registered from handleRegisterPlug's return value).
    fn broadcastPlugConnected(self: *Server, loop: *io.Loop, plug_name: []const u8) void {
        for (self.clients.items) |c| {
            if (c.plug_name != null) continue;
            if (c.closing) continue;
            self.sendPlugConnectedTo(loop, c, plug_name);
        }

        var map_items = self.allocator.alloc(msgpack.Value.KeyValue, 1) catch |err| {
            log.err("Failed to alloc plug_connected forward: {}", .{err});
            return;
        };
        defer self.allocator.free(map_items);
        map_items[0] = .{ .key = .{ .string = "plug" }, .value = .{ .string = plug_name } };

        const params = msgpack.Value{ .map = map_items };
        const msg_bytes = msgpack.encode(self.allocator, .{ 2, "plug_connected", params }) catch |err| {
            log.err("Failed to encode plug_connected forward: {}", .{err});
            return;
        };
        defer self.allocator.free(msg_bytes);

        const just_registered = self.plugs.get(plug_name);
        self.forwardToSubscribedPlugs("plug_connected", msg_bytes, just_registered);
    }

    /// Notify a single client about all already-registered plugs.
    fn notifyExistingPlugs(self: *Server, loop: *io.Loop, client: *Client) void {
        for (self.managed_plugs.items) |mp| {
            if (!mp.registered) continue;
            self.sendPlugConnectedTo(loop, client, mp.name);
        }
    }

    /// Notify all non-plug TUI clients that a plug has disconnected.
    /// Subscribed plugs also see the notification (see broadcastPlugConnected).
    /// Excludes the disconnecting plug itself so it does not receive its own
    /// farewell while finishClose is still tearing down the send path.
    fn broadcastPlugDisconnected(self: *Server, loop: *io.Loop, plug_name: []const u8) !void {
        var map_items = try self.allocator.alloc(msgpack.Value.KeyValue, 1);
        defer self.allocator.free(map_items);
        map_items[0] = .{ .key = .{ .string = "plug" }, .value = .{ .string = plug_name } };

        const params = msgpack.Value{ .map = map_items };
        const msg_bytes = try msgpack.encode(self.allocator, .{ 2, "plug_disconnected", params });
        defer self.allocator.free(msg_bytes);

        for (self.clients.items) |c| {
            if (c.plug_name != null) continue;
            if (c.closing) continue;
            c.sendData(loop, msg_bytes) catch |err| {
                log.err("Failed to send plug_disconnected to client fd={}: {}", .{ c.fd, err });
            };
        }

        const departing = self.plugs.get(plug_name);
        self.forwardToSubscribedPlugs("plug_disconnected", msg_bytes, departing);
    }

    /// Look up a managed plug by name. Returns null if not found.
    fn findManagedPlug(self: *Server, name: []const u8) ?*ManagedPlug {
        for (self.managed_plugs.items) |*mp| {
            if (std.mem.eql(u8, mp.name, name)) return mp;
        }
        return null;
    }

    /// Remove a managed plug by name, freeing its owned resources.
    fn removeManagedPlug(self: *Server, name: []const u8) void {
        for (self.managed_plugs.items, 0..) |*mp, i| {
            if (std.mem.eql(u8, mp.name, name)) {
                mp.deinit(self.allocator);
                _ = self.managed_plugs.swapRemove(i);
                return;
            }
        }
    }

    /// Forward a plug-originated notification to all non-plug TUI clients.
    fn forwardPlugNotification(self: *Server, loop: *io.Loop, notif: rpc.Notification, plug_name: []const u8) !void {
        const method_suffix = notif.method["plug.".len..];

        var map_items = try self.allocator.alloc(msgpack.Value.KeyValue, 3);
        defer self.allocator.free(map_items);
        map_items[0] = .{ .key = .{ .string = "plug" }, .value = .{ .string = plug_name } };
        map_items[1] = .{ .key = .{ .string = "method" }, .value = .{ .string = method_suffix } };
        map_items[2] = .{ .key = .{ .string = "params" }, .value = notif.params };

        const params = msgpack.Value{ .map = map_items };
        const msg_bytes = try msgpack.encode(self.allocator, .{ 2, "plug_notification", params });
        defer self.allocator.free(msg_bytes);

        for (self.clients.items) |c| {
            if (c.plug_name != null) continue;
            if (c.closing) continue;
            c.sendData(loop, msg_bytes) catch |err| {
                log.err("Failed to send plug_notification to client fd={}: {}", .{ c.fd, err });
            };
        }
    }

    /// Broadcast a session_file_changed notification to all TUI clients so
    /// anyone currently attached to the named session can reload their
    /// in-memory state from disk. Mirrors forwardPlugNotification's shape
    /// but uses a flat, prise-native method (no "plug." prefix) — this is
    /// prise's own coherence signal, not a plug-originated intent.
    fn broadcastSessionFileChanged(self: *Server, loop: *io.Loop, session_name: []const u8) !void {
        var map_items = try self.allocator.alloc(msgpack.Value.KeyValue, 1);
        defer self.allocator.free(map_items);
        map_items[0] = .{ .key = .{ .string = "session_name" }, .value = .{ .string = session_name } };

        const params: msgpack.Value = .{ .map = map_items };
        const msg_bytes = try msgpack.encode(self.allocator, .{ 2, "session_file_changed", params });
        defer self.allocator.free(msg_bytes);

        for (self.clients.items) |c| {
            if (c.plug_name != null) continue;
            if (c.closing) continue;
            c.sendData(loop, msg_bytes) catch |err| {
                log.err("Failed to send session_file_changed to client fd={}: {}", .{ c.fd, err });
            };
        }
    }

    // -- call forwarding handlers --

    /// Handle call_plug by forwarding the request to the target plug.
    /// Response will arrive asynchronously via handlePlugResponse.
    fn handleCallPlugDeferred(
        self: *Server,
        originator: *Client,
        orig_msgid: u32,
        params: msgpack.Value,
    ) !void {
        if (params != .map) return error.InvalidParams;

        var plug_name: ?[]const u8 = null;
        var method: ?[]const u8 = null;
        var call_params: msgpack.Value = .nil;

        for (params.map) |kv| {
            if (kv.key != .string) continue;
            if (std.mem.eql(u8, kv.key.string, "plug")) {
                plug_name = if (kv.value == .string) kv.value.string else null;
            } else if (std.mem.eql(u8, kv.key.string, "method")) {
                method = if (kv.value == .string) kv.value.string else null;
            } else if (std.mem.eql(u8, kv.key.string, "params")) {
                call_params = kv.value;
            }
        }

        const name = plug_name orelse return error.MissingPlugName;
        const meth = method orelse return error.MissingMethod;
        const plug_client = self.plugs.get(name) orelse return error.PlugNotFound;

        if (self.pending_forwards.count() >= LIMITS.PENDING_FORWARDS_MAX) {
            return error.TooManyPendingCalls;
        }

        // Skip forward_msgids that collide with in-flight entries
        var forward_msgid = self.next_forward_msgid;
        while (self.pending_forwards.contains(forward_msgid)) {
            forward_msgid +%= 1;
        }
        self.next_forward_msgid = forward_msgid +% 1;

        // Dupe plug_name — params are freed after we return
        const owned_plug_name = try self.allocator.dupe(u8, name);
        errdefer self.allocator.free(owned_plug_name);

        try self.pending_forwards.put(forward_msgid, .{
            .originator = originator,
            .orig_msgid = orig_msgid,
            .created_ms = std.time.milliTimestamp(),
            .plug_name = owned_plug_name,
        });
        // If sending to plug fails, remove the stale pending entry
        errdefer {
            _ = self.pending_forwards.remove(forward_msgid);
        }

        // Send request to plug: [0, forward_msgid, method, params]
        const request_arr = try self.allocator.alloc(msgpack.Value, 4);
        defer self.allocator.free(request_arr);
        request_arr[0] = .{ .unsigned = 0 };
        request_arr[1] = .{ .unsigned = forward_msgid };
        request_arr[2] = .{ .string = meth };
        request_arr[3] = call_params;

        const request_value = msgpack.Value{ .array = request_arr };
        const request_bytes = try msgpack.encodeFromValue(self.allocator, request_value);
        defer self.allocator.free(request_bytes);

        try plug_client.sendData(self.loop, request_bytes);

        log.info("Forwarded call to plug '{s}' method '{s}' forward_msgid={}", .{
            name, meth, forward_msgid,
        });
    }

    /// Route a plug's response back to the originating TUI client.
    fn handlePlugResponse(self: *Server, resp: rpc.Response) void {
        const pending = self.pending_forwards.fetchRemove(resp.msgid) orelse {
            log.warn("Response from plug with unknown forward_msgid={}", .{resp.msgid});
            return;
        };
        defer self.allocator.free(pending.value.plug_name);

        const originator = pending.value.originator;

        // Check if originator is still connected
        var found = false;
        for (self.clients.items) |c| {
            if (c == originator and !c.closing) {
                found = true;
                break;
            }
        }
        if (!found) {
            log.info("Originator disconnected, dropping response for msgid={}", .{
                pending.value.orig_msgid,
            });
            return;
        }

        // Build response: [1, orig_msgid, error, result]
        const response_arr = self.allocator.alloc(msgpack.Value, 4) catch {
            log.err("OOM building forwarded response", .{});
            return;
        };
        defer self.allocator.free(response_arr);
        response_arr[0] = .{ .unsigned = 1 };
        response_arr[1] = .{ .unsigned = pending.value.orig_msgid };
        response_arr[2] = resp.err orelse .nil;
        response_arr[3] = resp.result;

        const response_value = msgpack.Value{ .array = response_arr };
        const response_bytes = msgpack.encodeFromValue(self.allocator, response_value) catch {
            log.err("Failed to encode forwarded response", .{});
            return;
        };
        defer self.allocator.free(response_bytes);

        originator.sendData(self.loop, response_bytes) catch |err| {
            log.err("Failed to send forwarded response: {}", .{err});
        };
    }

    /// Send a notification to a plug (fire and forget, no response).
    fn handleNotifyPlug(self: *Server, params: msgpack.Value) !msgpack.Value {
        if (params != .map) return error.InvalidParams;

        var plug_name: ?[]const u8 = null;
        var method: ?[]const u8 = null;
        var notif_params: msgpack.Value = .nil;

        for (params.map) |kv| {
            if (kv.key != .string) continue;
            if (std.mem.eql(u8, kv.key.string, "plug")) {
                plug_name = if (kv.value == .string) kv.value.string else null;
            } else if (std.mem.eql(u8, kv.key.string, "method")) {
                method = if (kv.value == .string) kv.value.string else null;
            } else if (std.mem.eql(u8, kv.key.string, "params")) {
                notif_params = kv.value;
            }
        }

        const name = plug_name orelse return error.MissingPlugName;
        const meth = method orelse return error.MissingMethod;
        const plug_client = self.plugs.get(name) orelse return error.PlugNotFound;

        // Send notification: [2, method, params]
        const msg_bytes = try msgpack.encode(self.allocator, .{ 2, meth, notif_params });
        defer self.allocator.free(msg_bytes);

        try plug_client.sendData(self.loop, msg_bytes);

        return msgpack.Value{ .string = try self.allocator.dupe(u8, "ok") };
    }

    /// Send a notification to a single client addressed by its monotonic id.
    /// The megaplug dispatches UI-specific notifications through this path —
    /// per-client refocus commands, targeted state snapshots, etc.
    fn handleNotifyPlugClient(self: *Server, params: msgpack.Value) !msgpack.Value {
        if (params != .map) return error.InvalidParams;

        var client_id: ?usize = null;
        var method: ?[]const u8 = null;
        var notif_params: msgpack.Value = .nil;

        for (params.map) |kv| {
            if (kv.key != .string) continue;
            if (std.mem.eql(u8, kv.key.string, "client_id")) {
                client_id = switch (kv.value) {
                    .unsigned => |u| u,
                    .integer => |i| if (i >= 0) @intCast(i) else null,
                    else => null,
                };
            } else if (std.mem.eql(u8, kv.key.string, "method")) {
                method = if (kv.value == .string) kv.value.string else null;
            } else if (std.mem.eql(u8, kv.key.string, "params")) {
                notif_params = kv.value;
            }
        }

        const cid = client_id orelse return error.MissingClientId;
        const meth = method orelse return error.MissingMethod;

        const target = blk: {
            for (self.clients.items) |c| {
                if (c.id == cid) break :blk c;
            }
            return error.ClientNotFound;
        };

        const msg_bytes = try msgpack.encode(self.allocator, .{ 2, meth, notif_params });
        defer self.allocator.free(msg_bytes);

        try target.sendData(self.loop, msg_bytes);

        return msgpack.Value{ .string = try self.allocator.dupe(u8, "ok") };
    }

    // -- spawn_plug types and handlers --

    const SpawnPlugParams = struct {
        name: []const u8,
        cmd: []const msgpack.Value,
        restart: bool,
        restart_delay_ms: u32,
    };

    fn parseSpawnPlugParams(params: msgpack.Value) ?SpawnPlugParams {
        if (params != .map) return null;

        var name: ?[]const u8 = null;
        var cmd: ?[]const msgpack.Value = null;
        var restart: bool = false;
        var restart_delay_ms: u32 = 1000;

        for (params.map) |kv| {
            if (kv.key != .string) continue;
            const k = kv.key.string;
            if (std.mem.eql(u8, k, "name")) {
                name = if (kv.value == .string) kv.value.string else null;
            } else if (std.mem.eql(u8, k, "cmd")) {
                cmd = if (kv.value == .array) kv.value.array else null;
            } else if (std.mem.eql(u8, k, "restart")) {
                restart = if (kv.value == .boolean) kv.value.boolean else false;
            } else if (std.mem.eql(u8, k, "restart_delay_ms")) {
                restart_delay_ms = switch (kv.value) {
                    .unsigned => |u| std.math.cast(u32, u) orelse 1000,
                    .integer => |i| if (i > 0) std.math.cast(u32, i) orelse 1000 else 1000,
                    else => 1000,
                };
            }
        }

        const plug_name = name orelse return null;
        const cmd_arr = cmd orelse return null;
        if (cmd_arr.len == 0 or cmd_arr.len > 64) return null;

        // Validate all cmd elements are strings
        for (cmd_arr) |item| {
            if (item != .string) return null;
        }

        return .{
            .name = plug_name,
            .cmd = cmd_arr,
            .restart = restart,
            .restart_delay_ms = restart_delay_ms,
        };
    }

    /// Handle spawn_plug RPC. Spawns a child process with PRISE_SOCKET set.
    fn handleSpawnPlug(self: *Server, params: msgpack.Value) !msgpack.Value {
        const parsed = parseSpawnPlugParams(params) orelse {
            return error.InvalidParams;
        };

        if (parsed.name.len == 0 or parsed.name.len > LIMITS.PLUG_NAME_MAX) {
            return error.InvalidPlugName;
        }

        // Idempotent: if a managed plug with this name exists, check state and config
        if (self.findManagedPlug(parsed.name)) |mp| {
            // Config-owned plugs cannot be reconfigured via RPC. Reject before
            // any state inspection — the TOML declaration is the source of
            // truth for a config-owned name.
            if (mp.owner == .config) {
                return error.PlugConfigOwned;
            }
            const active = mp.pid != null or mp.restart_timer_task != null or mp.registered;
            if (active) {
                if (plugCmdMatchesParsed(mp.cmd, parsed.cmd) and
                    mp.restart == parsed.restart and
                    mp.restart_delay_ms == parsed.restart_delay_ms)
                {
                    return msgpack.Value{ .string = try self.allocator.dupe(u8, "ok") };
                }
                return error.PlugConfigConflict;
            }
            // Stopped plug — remove stale entry so we can re-spawn below
            self.removeManagedPlug(parsed.name);
        }
        if (self.plugs.contains(parsed.name)) {
            // Externally connected plug — cannot verify command
            return error.PlugConfigConflict;
        }

        // Dupe cmd args from msgpack values into owned strings, then hand off
        // to the shared spawnManagedPlug helper that the TOML loader also uses.
        const owned_cmd = try self.dupePlugCmd(parsed.cmd);
        errdefer self.freePlugCmd(owned_cmd);

        try self.spawnManagedPlug(
            parsed.name,
            owned_cmd,
            parsed.restart,
            parsed.restart_delay_ms,
            .rpc,
        );
        return msgpack.Value{ .string = try self.allocator.dupe(u8, "ok") };
    }

    /// Spawn a child process and register it as a managed plug. Takes
    /// ownership of `cmd` on success (frees on failure). The caller must dupe
    /// `name` into a value the caller does not need; this helper dupes it
    /// internally.
    ///
    /// Used by both the spawn_plug RPC handler and the TOML config loader.
    /// Centralizes: name dupe, token gen, child spawn, waitpid registration,
    /// managed_plugs.append. Reuses spawnPlugProcess unchanged.
    fn spawnManagedPlug(
        self: *Server,
        name: []const u8,
        cmd: []const []const u8,
        restart: bool,
        restart_delay_ms: u32,
        owner: PlugOwner,
    ) !void {
        const owned_name = try self.allocator.dupe(u8, name);
        errdefer self.allocator.free(owned_name);

        const token = generatePlugToken();
        const pid = try self.spawnPlugProcess(cmd, &token);
        const task = try self.loop.waitpid(pid, .{
            .ptr = self,
            .cb = onPlugExit,
        });

        try self.managed_plugs.append(self.allocator, .{
            .name = owned_name,
            .cmd = cmd,
            .restart = restart,
            .restart_delay_ms = restart_delay_ms,
            .owner = owner,
            .token = token,
            .pid = pid,
            .waitpid_task = task,
        });

        log.info("Spawned plug '{s}' pid={} owner={s}", .{ owned_name, pid, @tagName(owner) });
    }

    /// Dupe an array of msgpack string values into owned slices.
    fn dupePlugCmd(self: *Server, cmd_values: []const msgpack.Value) ![]const []const u8 {
        const owned = try self.allocator.alloc([]const u8, cmd_values.len);
        var i: usize = 0;
        errdefer {
            for (owned[0..i]) |arg| self.allocator.free(arg);
            self.allocator.free(owned);
        }
        for (cmd_values) |item| {
            owned[i] = try self.allocator.dupe(u8, item.string);
            i += 1;
        }
        return owned;
    }

    fn freePlugCmd(self: *Server, cmd: []const []const u8) void {
        for (cmd) |arg| self.allocator.free(arg);
        self.allocator.free(cmd);
    }

    fn generatePlugToken() [LIMITS.PLUG_TOKEN_HEX_LEN]u8 {
        var raw: [LIMITS.PLUG_TOKEN_BYTES]u8 = undefined;
        std.crypto.random.bytes(&raw);
        return std.fmt.bytesToHex(raw, .lower);
    }

    /// Spawn a child process with PRISE_SOCKET and PRISE_PLUG_TOKEN in the environment.
    fn spawnPlugProcess(self: *Server, cmd: []const []const u8, token: *const [LIMITS.PLUG_TOKEN_HEX_LEN]u8) !posix.pid_t {
        var env_map = std.process.getEnvMap(self.allocator) catch
            return error.SpawnFailed;
        defer env_map.deinit();
        env_map.put("PRISE_SOCKET", self.socket_path) catch
            return error.SpawnFailed;
        env_map.put("PRISE_PLUG_TOKEN", token) catch
            return error.SpawnFailed;

        var child = std.process.Child.init(cmd, self.allocator);
        child.stdin_behavior = .Ignore;
        child.stdout_behavior = .Ignore;
        child.stderr_behavior = .Ignore;
        child.env_map = &env_map;

        child.spawn() catch return error.SpawnFailed;
        // Close the internal err_pipe and detect exec failures synchronously.
        // Without this, every spawn leaks an FD in the parent.
        child.waitForSpawn() catch return error.SpawnFailed;
        return child.id;
    }

    /// Callback when a managed plug process exits (via loop.waitpid).
    fn onPlugExit(loop: *io.Loop, completion: io.Completion) anyerror!void {
        const self = completion.userdataCast(Server);

        const exit_pid = switch (completion.result) {
            .waitpid => |r| r.pid,
            .err => |err| {
                log.err("waitpid error for plug: {}", .{err});
                return;
            },
            else => return,
        };

        for (self.managed_plugs.items) |*mp| {
            if (mp.pid != exit_pid) continue;

            log.info("Plug '{s}' (pid={}) exited", .{ mp.name, exit_pid });
            mp.pid = null;
            mp.waitpid_task = null;

            if (mp.registered) {
                // Wrapper exited but child still owns the socket.
                // Defer cleanup and restart to finishClose.
                log.info("Plug '{s}' process exited but still registered, deferring cleanup", .{mp.name});
                return;
            }

            // Plug never registered — proceed with teardown
            mp.registered = false;

            // Proactively remove old registration from plugs map so restart
            // doesn't race with finishClose. Without this, a fast-restarting
            // plug hits DuplicatePlugName because the old client hasn't closed yet.
            // finishClose checks plug_name against the map and skips if absent.
            _ = self.plugs.remove(mp.name);

            if (mp.restart and !mp.killed_by_server and !self.shutting_down) {
                mp.restart_count += 1;
                self.schedulePlugRestart(loop, mp) catch |err| {
                    log.err("Failed to schedule restart for '{s}': {}", .{ mp.name, err });
                };
            }
            return;
        }
    }

    /// Schedule a plug process restart after the configured delay.
    fn schedulePlugRestart(self: *Server, loop: *io.Loop, mp: *ManagedPlug) !void {
        if (mp.restart_delay_ms == 0) {
            self.restartPlug(loop, mp) catch |err| {
                log.err("Failed to restart plug '{s}': {}", .{ mp.name, err });
            };
            return;
        }

        // Dupe plug name — ManagedPlug may be freed before timer fires
        const owned_name = try self.allocator.dupe(u8, mp.name);
        errdefer self.allocator.free(owned_name);

        const ctx = try self.allocator.create(RestartContext);
        ctx.* = .{ .server = self, .plug_name = owned_name };

        const delay_ns: u64 = @as(u64, mp.restart_delay_ms) * std.time.ns_per_ms;
        const task = try loop.timeout(delay_ns, .{
            .ptr = ctx,
            .cb = onRestartTimer,
        });

        // Store so shutdown can cancel the timer and free context
        mp.restart_timer_task = task;
        mp.restart_ctx = ctx;
    }

    fn onRestartTimer(loop: *io.Loop, completion: io.Completion) anyerror!void {
        const ctx = completion.userdataCast(RestartContext);
        const server = ctx.server;
        defer {
            server.allocator.free(ctx.plug_name);
            server.allocator.destroy(ctx);
        }

        // Clear references on the managed plug now that the timer fired
        for (server.managed_plugs.items) |*mp| {
            if (mp.restart_ctx == ctx) {
                mp.restart_timer_task = null;
                mp.restart_ctx = null;
                break;
            }
        }

        if (server.shutting_down) return;

        for (server.managed_plugs.items) |*mp| {
            if (!std.mem.eql(u8, mp.name, ctx.plug_name)) continue;
            if (mp.pid != null or mp.registered) return; // already restarted or late-registered
            server.restartPlug(loop, mp) catch |err| {
                log.err("Failed to restart plug '{s}': {}", .{ mp.name, err });
            };
            return;
        }
    }

    fn restartPlug(self: *Server, loop: *io.Loop, mp: *ManagedPlug) !void {
        log.info("Restarting plug '{s}' (attempt {})", .{ mp.name, mp.restart_count });
        const token = generatePlugToken();
        mp.token = token;
        const pid = try self.spawnPlugProcess(mp.cmd, &token);
        mp.pid = pid;
        mp.killed_by_server = false;
        mp.waitpid_task = try loop.waitpid(pid, .{
            .ptr = self,
            .cb = onPlugExit,
        });
    }

    fn shouldExit(self: *Server) bool {
        return self.exit_on_idle and self.clients.items.len == 0;
    }

    fn checkExit(self: *Server) !void {
        if (self.shouldExit() and self.accepting) {
            self.accepting = false;
            if (self.accept_task) |*task| {
                try task.cancel(self.loop);
                self.accept_task = null;
            }
        }
    }

    fn onAccept(loop: *io.Loop, completion: io.Completion) anyerror!void {
        const self = completion.userdataCast(Server);

        switch (completion.result) {
            .accept => |client_fd| {
                std.log.debug("Accepted client connection fd={}", .{client_fd});

                if (self.clients.items.len >= LIMITS.CLIENTS_MAX) {
                    std.log.warn("Client limit reached ({}), rejecting connection", .{LIMITS.CLIENTS_MAX});
                    _ = try loop.close(client_fd, .{
                        .ptr = null,
                        .cb = struct {
                            fn noop(_: *io.Loop, _: io.Completion) anyerror!void {}
                        }.noop,
                    });
                    // Queue next accept if still accepting
                    if (self.accepting) {
                        self.accept_task = try loop.accept(self.listen_fd, .{
                            .ptr = self,
                            .cb = onAccept,
                        });
                    }
                    return;
                }

                const assigned_id = self.next_client_id;
                self.next_client_id += 1;

                const client = try self.allocator.create(Client);
                client.* = .{
                    .id = assigned_id,
                    .fd = client_fd,
                    .server = self,
                    .msg_buffer = std.ArrayList(u8).empty,
                    .send_queue = std.ArrayList([]u8).empty,
                    .attached_ptys = std.ArrayList(usize).empty,
                    // .style_cache = std.AutoHashMap(u16, redraw.UIEvent.Style.Attributes).init(self.allocator),
                };
                try self.clients.append(self.allocator, client);
                std.debug.assert(self.clients.items.len <= LIMITS.CLIENTS_MAX);
                std.log.debug("Total clients: {} (assigned id={})", .{ self.clients.items.len, client.id });
                crash_context.record("client accepted fd={d}", .{client_fd});

                // Start recv to detect disconnect
                _ = try loop.recv(client_fd, &client.recv_buffer, .{
                    .ptr = client,
                    .cb = Client.onRecv,
                });

                // Existing plug notifications are deferred to the first RPC
                // (in handleRequest) so plug clients don't receive unsolicited
                // messages before the register_plug response.

                // Queue next accept if still accepting
                if (self.accepting) {
                    self.accept_task = try loop.accept(self.listen_fd, .{
                        .ptr = self,
                        .cb = onAccept,
                    });
                }
            },
            .err => |err| {
                std.log.err("Accept error: {}", .{err});
            },
            else => unreachable,
        }
    }

    fn removeClient(self: *Server, client: *Client) void {
        std.log.debug("Removing client fd={}", .{client.fd});

        // Sweep pending broker-RPC entries that mention `client`. A
        // single pending entry matches at most one of these cases (the
        // CLI and broker are distinct clients in the normal flow):
        //
        //   broker-side (broker_id == client.id): synthesise a
        //     `broker_timeout` reply to the CLI before its 2s deadline,
        //     since we know the broker is gone. Drop the entry.
        //   cli-side  (cli_client == client):     the CLI socket is
        //     already closing — no Response can be delivered. Drop
        //     the entry without replying.
        //
        // Snapshot-then-iterate to avoid hashmap iterator invalidation
        // while we mutate via `remove`. Per-CLI send failures are
        // logged and the loop continues.
        var to_drop = std.ArrayList(usize).empty;
        defer to_drop.deinit(self.allocator);

        var pending_it = self.pending.iterator();
        while (pending_it.next()) |entry| {
            if (entry.value_ptr.broker_id == client.id or
                entry.value_ptr.cli_client == client)
            {
                to_drop.append(self.allocator, entry.key_ptr.*) catch |err| {
                    log.warn("removeClient: pending snapshot append failed: {}", .{err});
                    break;
                };
            }
        }

        for (to_drop.items) |request_id| {
            const entry = self.pending.fetchRemove(request_id) orelse continue;
            const broker_gone = entry.value.broker_id == client.id;
            const cli_gone = entry.value.cli_client == client;

            if (broker_gone and !cli_gone) {
                log.info("event=\"rpc.broker.disconnect\" request_id={} broker_id={}", .{
                    request_id,
                    entry.value.broker_id,
                });
                entry.value.cli_client.sendBreakPaneResponse(
                    self.loop,
                    entry.value.cli_msgid,
                    false,
                    "broker_timeout",
                ) catch |err| {
                    log.warn("removeClient: broker_timeout reply failed: {}", .{err});
                };
            } else {
                // cli_gone (or both, in a pathological self-broker case
                // — drop without replying since the CLI socket is gone).
                log.info("event=\"rpc.broker.cli_disconnect\" request_id={}", .{request_id});
            }
        }

        // Remove client from any PTYs it was attached to (but don't kill them)
        for (client.attached_ptys.items) |pty_id| {
            if (self.ptys.get(pty_id)) |pty_instance| {
                pty_instance.removeClient(client);
            }
        }

        // Mark as closing to prevent new sends
        client.closing = true;

        // Cancel pending recv on this client's FD
        self.loop.cancelByFd(client.fd);

        // cancelByFd silently drops pending sends — onSendComplete will never fire.
        // Free the cancelled send buffer so finishClose always runs.
        if (client.send_buffer) |buf| {
            self.allocator.free(buf);
            client.send_buffer = null;
            client.send_offset = 0;
        }

        client.finishClose(self.loop);
    }

    /// Send a `break_pane_request` Notification to the chosen broker.
    ///
    /// Mirrors `sendRedraw`'s targeted-send filter pattern: walk all
    /// clients, skip those whose id doesn't match `broker_id`, send to
    /// exactly one. The wire envelope is `[2, "break_pane_request",
    /// {pty_id, focus, request_id}]`. The broker correlates the reply
    /// via `request_id` in the payload (msgpack-RPC Notifications carry
    /// no msgid, so correlation must live in the params).
    ///
    /// Returns `error.BrokerNotFound` if no client matches `broker_id`
    /// (raced with `removeClient`); caller drops the pending entry and
    /// replies `broker_timeout` to the CLI.
    fn sendBreakPaneRequest(self: *Server, broker_id: usize, pty_id: u32, focus: bool, request_id: usize) !void {
        var target: ?*Client = null;
        for (self.clients.items) |c| {
            if (c.id == broker_id) {
                target = c;
                break;
            }
        }
        const broker = target orelse return error.BrokerNotFound;

        const map_items = try self.allocator.alloc(msgpack.Value.KeyValue, 3);
        defer self.allocator.free(map_items);
        map_items[0] = .{
            .key = .{ .string = "pty_id" },
            .value = .{ .unsigned = pty_id },
        };
        map_items[1] = .{
            .key = .{ .string = "focus" },
            .value = .{ .boolean = focus },
        };
        map_items[2] = .{
            .key = .{ .string = "request_id" },
            .value = .{ .unsigned = request_id },
        };

        const params = msgpack.Value{ .map = map_items };
        const msg_bytes = try msgpack.encode(self.allocator, .{ 2, "break_pane_request", params });
        defer self.allocator.free(msg_bytes);

        log.info("break_pane_request: broker_id={} pty_id={} focus={} request_id={}", .{
            broker_id,
            pty_id,
            focus,
            request_id,
        });

        try broker.sendData(self.loop, msg_bytes);
    }

    /// Broadcast a `break_pane_applied` Notification to all attached
    /// clients EXCEPT the broker. Mirrors `sendPtyExited`'s loop, but
    /// gates on `attached_ptys.items.len > 0` (only attached UIs care)
    /// and skips the broker (which already knows — it just applied
    /// the change locally and reported `ok=true`).
    ///
    /// Wire envelope: `[2, "break_pane_applied", {pty_id, focus}]`.
    /// Sibling clients use this to converge their tile-tree mirror
    /// without having to refetch state.
    ///
    /// Best-effort per-client: a per-client send failure is logged
    /// and the loop continues — one stuck client must not block
    /// convergence on the others.
    fn sendBreakPaneApplied(self: *Server, broker_id: usize, pty_id: u32, focus: bool) !void {
        const map_items = try self.allocator.alloc(msgpack.Value.KeyValue, 2);
        defer self.allocator.free(map_items);
        map_items[0] = .{
            .key = .{ .string = "pty_id" },
            .value = .{ .unsigned = pty_id },
        };
        map_items[1] = .{
            .key = .{ .string = "focus" },
            .value = .{ .boolean = focus },
        };

        const params = msgpack.Value{ .map = map_items };
        const msg_bytes = try msgpack.encode(self.allocator, .{ 2, "break_pane_applied", params });
        defer self.allocator.free(msg_bytes);

        log.info("break_pane_applied: pty_id={} focus={} (excluding broker_id={})", .{
            pty_id,
            focus,
            broker_id,
        });

        for (self.clients.items) |client| {
            if (client.id == broker_id) continue;
            if (client.attached_ptys.items.len == 0) continue;
            client.sendData(self.loop, msg_bytes) catch |err| {
                log.warn("break_pane_applied: send to client id={} failed: {}", .{ client.id, err });
            };
        }
    }

    /// Sweep `pending` for expired entries and reply `broker_timeout`
    /// to each originating CLI. Snapshot-then-iterate to avoid
    /// hashmap iterator invalidation while we mutate via `remove`.
    ///
    /// "Expired" means `deadline_ts < now()`. The deadline is set to
    /// `now() + LIMITS.PENDING_DEADLINE_MS` at `handleBreakPane` time.
    /// Per-CLI send failures are logged and the loop continues — one
    /// dead socket must not stall sweep of the others.
    fn sweepPending(self: *Server) void {
        const now = std.time.milliTimestamp();

        // Snapshot the request_ids that are expired. We can't call
        // sendBreakPaneResponse + remove inside the iterator because
        // sendBreakPaneResponse may queue a send completion that
        // mutates the loop, and remove invalidates the iterator.
        var expired = std.ArrayList(usize).empty;
        defer expired.deinit(self.allocator);

        var it = self.pending.iterator();
        while (it.next()) |entry| {
            if (entry.value_ptr.deadline_ts < now) {
                expired.append(self.allocator, entry.key_ptr.*) catch |err| {
                    log.warn("sweepPending: append failed: {}", .{err});
                    return;
                };
            }
        }

        for (expired.items) |request_id| {
            const entry = self.pending.fetchRemove(request_id) orelse continue;
            log.info("event=\"rpc.broker.timeout\" request_id={} broker_id={}", .{
                request_id,
                entry.value.broker_id,
            });
            entry.value.cli_client.sendBreakPaneResponse(
                self.loop,
                entry.value.cli_msgid,
                false,
                "broker_timeout",
            ) catch |err| {
                log.warn("sweepPending: sendBreakPaneResponse failed: {}", .{err});
            };
        }
    }

    /// Arm (or re-arm) the deadline-sweep timer at `PENDING_SWEEP_MS`.
    /// Called once at `startServer`, then re-armed from the timer
    /// callback. Idempotent: if a timer is already armed, no-op.
    fn armPendingSweepTimer(self: *Server) !void {
        if (self.pending_sweep_timer != null) return;
        self.pending_sweep_timer = try self.loop.timeout(
            LIMITS.PENDING_SWEEP_MS * std.time.ns_per_ms,
            .{ .ptr = self, .cb = onPendingSweepTimer },
        );
    }

    fn onPendingSweepTimer(loop: *io.Loop, completion: io.Completion) anyerror!void {
        _ = loop;
        const self = completion.userdataCast(Server);
        // Clear the handle BEFORE sweep + re-arm so we don't dedup
        // ourselves against a timer-id we've already consumed.
        self.pending_sweep_timer = null;
        self.sweepPending();
        // Re-arm only while the server is still accepting. Past
        // shutdown, the loop is draining; arming again would keep it
        // alive past the shutdown signal.
        if (self.accepting) {
            try self.armPendingSweepTimer();
        }
    }

    /// Drain ALL in-flight broker-RPC requests, regardless of
    /// deadline, with best-effort `broker_timeout` replies. Called
    /// from `shutdown` BEFORE clients are removed: once the CLI
    /// client's socket is closed, no Response can be queued on it.
    ///
    /// Best-effort means: per-CLI send failures are logged and the
    /// drain continues. The map is cleared at the end so a second
    /// shutdown call is a no-op.
    fn drainPendingForShutdown(self: *Server) void {
        var it = self.pending.iterator();
        while (it.next()) |entry| {
            log.info("event=\"rpc.broker.shutdown_drain\" request_id={}", .{entry.key_ptr.*});
            entry.value_ptr.cli_client.sendBreakPaneResponse(
                self.loop,
                entry.value_ptr.cli_msgid,
                false,
                "broker_timeout",
            ) catch |err| {
                log.warn("drainPendingForShutdown: reply failed: {}", .{err});
            };
        }
        self.pending.clearRetainingCapacity();
    }

    /// Send redraw notification (bytes) to attached clients
    fn sendRedraw(self: *Server, loop: *io.Loop, pty_instance: *Pty, msg: []const u8, target_client: ?*Client) !void {
        // Send to each client attached to this session
        for (self.clients.items) |client| {
            // If we have a target client, skip others
            if (target_client) |target| {
                if (client != target) {
                    continue;
                }
            }

            // Check if client is attached to this pty
            var attached = false;
            for (client.attached_ptys.items) |pid| {
                if (pid == pty_instance.id) {
                    attached = true;
                    break;
                }
            }
            if (!attached) {
                continue;
            }

            try client.sendData(loop, msg);
        }
    }

    fn renderFrame(self: *Server, pty_instance: *Pty) void {
        if (pty_instance.clients.items.len == 0) return;

        const msg = buildRedrawMessageFromPty(
            self.allocator,
            pty_instance,
            .incremental,
        ) catch |err| {
            std.log.err("Failed to build redraw message for session {}: {}", .{ pty_instance.id, err });
            return;
        };
        defer self.allocator.free(msg);

        // Build and send redraw notifications
        self.sendRedraw(self.loop, pty_instance, msg, null) catch |err| {
            std.log.err("Failed to send redraw for session {}: {}", .{ pty_instance.id, err });
        };

        // Send cwd_changed notification if cwd is dirty
        // Lock mutex to read+clear cwd_dirty and dupe cwd (read thread may reallocate)
        const cwd_update = blk: {
            pty_instance.terminal_mutex.lock();
            defer pty_instance.terminal_mutex.unlock();
            if (!pty_instance.cwd_dirty) break :blk @as(?[]u8, null);
            const cwd_copy = self.allocator.dupe(u8, pty_instance.cwd.items) catch
                break :blk @as(?[]u8, null);
            pty_instance.cwd_dirty = false;
            break :blk @as(?[]u8, cwd_copy);
        };
        if (cwd_update) |cwd_copy| {
            defer self.allocator.free(cwd_copy);
            self.sendCwdChanged(pty_instance, cwd_copy) catch |err| {
                std.log.err("Failed to send cwd_changed for pty {}: {}", .{ pty_instance.id, err });
            };
        }

        // Send pending color_query notifications
        self.sendColorQueries(pty_instance) catch |err| {
            std.log.err("Failed to send color_query for pty {}: {}", .{ pty_instance.id, err });
        };

        // Update timestamp
        pty_instance.last_render_time = std.time.milliTimestamp();
    }

    /// Handle session_switch RPC: find the client owning the given PTY and
    /// send it a session_switch notification so it calls switchToSession.
    fn handleSessionSwitch(self: *Server, params: msgpack.Value) !msgpack.Value {
        if (params != .map) return msgpack.Value{ .string = try self.allocator.dupe(u8, "invalid params") };

        var pty_id: ?usize = null;
        var session: ?[]const u8 = null;

        for (params.map) |kv| {
            if (kv.key != .string) continue;
            if (std.mem.eql(u8, kv.key.string, "pty_id")) {
                pty_id = switch (kv.value) {
                    .unsigned => |u| @intCast(u),
                    .integer => |i| @intCast(i),
                    else => null,
                };
            } else if (std.mem.eql(u8, kv.key.string, "session")) {
                session = if (kv.value == .string) kv.value.string else null;
            }
        }

        const target_pty_id = pty_id orelse return msgpack.Value{ .string = try self.allocator.dupe(u8, "missing pty_id") };
        const target_session = session orelse return msgpack.Value{ .string = try self.allocator.dupe(u8, "missing session") };

        // Find which client owns this PTY
        var target_client: ?*Client = null;
        for (self.clients.items) |c| {
            for (c.attached_ptys.items) |pid| {
                if (pid == target_pty_id) {
                    target_client = c;
                    break;
                }
            }
            if (target_client != null) break;
        }

        const owner = target_client orelse return msgpack.Value{ .string = try self.allocator.dupe(u8, "PTY not attached to any client") };

        // Send session_switch notification to the owning client
        var map_items = try self.allocator.alloc(msgpack.Value.KeyValue, 1);
        defer self.allocator.free(map_items);
        map_items[0] = .{ .key = .{ .string = "session" }, .value = .{ .string = target_session } };

        const notif_params = msgpack.Value{ .map = map_items };
        const msg_bytes = try msgpack.encode(self.allocator, .{ 2, "session_switch", notif_params });
        defer self.allocator.free(msg_bytes);

        try owner.sendData(self.loop, msg_bytes);

        log.info("Sent session_switch notification to client for PTY {} -> session '{s}'", .{ target_pty_id, target_session });
        return msgpack.Value{ .boolean = true };
    }

    /// Forward a pre-encoded notification to all plugs subscribed to the given event.
    fn forwardToSubscribedPlugs(self: *Server, event_name: []const u8, msg_bytes: []const u8, exclude_client: ?*Client) void {
        var iter = self.plugs.valueIterator();
        while (iter.next()) |client_ptr| {
            const client = client_ptr.*;
            if (client.closing) continue;
            if (exclude_client) |excluded| {
                if (client == excluded) continue;
            }
            if (!client.isSubscribedPlug(event_name)) continue;
            client.sendData(self.loop, msg_bytes) catch |err| {
                log.err("Failed to forward {s} to plug '{s}': {}", .{
                    event_name,
                    client.plug_name orelse "unknown",
                    err,
                });
            };
        }
    }

    /// Encode a single-key map `{client_id: id}` and forward it to subscribed
    /// plugs under the given event name. Used for client_connected and
    /// client_disconnected. Allocation failures are logged and swallowed —
    /// one missed event does not warrant unwinding the caller.
    fn forwardClientEvent(self: *Server, event_name: []const u8, client_id: usize) void {
        var map_items = self.allocator.alloc(msgpack.Value.KeyValue, 1) catch |err| {
            log.err("Failed to alloc {s} forward: {}", .{ event_name, err });
            return;
        };
        defer self.allocator.free(map_items);
        map_items[0] = .{ .key = .{ .string = "client_id" }, .value = .{ .unsigned = client_id } };

        const params = msgpack.Value{ .map = map_items };
        const msg_bytes = msgpack.encode(self.allocator, .{ 2, event_name, params }) catch |err| {
            log.err("Failed to encode {s} forward: {}", .{ event_name, err });
            return;
        };
        defer self.allocator.free(msg_bytes);

        self.forwardToSubscribedPlugs(event_name, msg_bytes, null);
    }

    /// Encode `{client_id, pty_id}` and forward it to subscribed plugs. Used
    /// for pty_attach and pty_detach — a plug subscribed to either gets the
    /// pair that lets it reconstruct which client is holding which pty.
    fn forwardPtyClientEvent(self: *Server, event_name: []const u8, client_id: usize, pty_id: usize) void {
        var map_items = self.allocator.alloc(msgpack.Value.KeyValue, 2) catch |err| {
            log.err("Failed to alloc {s} forward: {}", .{ event_name, err });
            return;
        };
        defer self.allocator.free(map_items);
        map_items[0] = .{ .key = .{ .string = "client_id" }, .value = .{ .unsigned = client_id } };
        map_items[1] = .{ .key = .{ .string = "pty_id" }, .value = .{ .unsigned = pty_id } };

        const params = msgpack.Value{ .map = map_items };
        const msg_bytes = msgpack.encode(self.allocator, .{ 2, event_name, params }) catch |err| {
            log.err("Failed to encode {s} forward: {}", .{ event_name, err });
            return;
        };
        defer self.allocator.free(msg_bytes);

        self.forwardToSubscribedPlugs(event_name, msg_bytes, null);
    }

    /// Build and send pty_exited notification to all clients
    fn sendPtyExited(self: *Server, pty_id: usize, exit_status: u32) !void {
        const params = .{ pty_id, exit_status };
        const msg_bytes = try msgpack.encode(self.allocator, .{ 2, "pty_exited", params });
        defer self.allocator.free(msg_bytes);

        std.log.info("Sending pty_exited for session {} status {}", .{ pty_id, exit_status });
        crash_context.record("pty exited pty_id={d} status={d}", .{ pty_id, exit_status });

        // Send only to non-plug TUI clients. Plugs receive events via
        // forwardToSubscribedPlugs which filters by subscription. Also skip
        // managed plug sockets that haven't registered yet.
        for (self.clients.items) |client| {
            if (client.plug_name != null) continue;
            try client.sendData(self.loop, msg_bytes);
        }

        // Forward to subscribed plugs
        self.forwardToSubscribedPlugs("pty_exited", msg_bytes, null);
    }

    /// Build and send pty_spawned notification to all clients
    fn sendPtySpawned(self: *Server, pty_id: usize, cwd: []const u8, session: ?[]const u8, tab: ?[]const u8, title: ?[]const u8, focus: ?bool) !void {
        var field_count: usize = 2; // id + cwd always present
        if (session != null) field_count += 1;
        if (tab != null) field_count += 1;
        if (title != null) field_count += 1;
        if (focus != null) field_count += 1;

        const params = try self.allocator.alloc(msgpack.Value.KeyValue, field_count);
        defer self.allocator.free(params);

        var idx: usize = 0;
        params[idx] = .{ .key = .{ .string = "id" }, .value = .{ .unsigned = pty_id } };
        idx += 1;
        params[idx] = .{ .key = .{ .string = "cwd" }, .value = .{ .string = cwd } };
        idx += 1;
        if (session) |s| {
            params[idx] = .{ .key = .{ .string = "session" }, .value = .{ .string = s } };
            idx += 1;
        }
        if (tab) |t| {
            params[idx] = .{ .key = .{ .string = "tab" }, .value = .{ .string = t } };
            idx += 1;
        }
        if (title) |t| {
            params[idx] = .{ .key = .{ .string = "title" }, .value = .{ .string = t } };
            idx += 1;
        }
        if (focus) |f| {
            params[idx] = .{ .key = .{ .string = "focus" }, .value = .{ .boolean = f } };
            idx += 1;
        }

        const params_value = msgpack.Value{ .map = params };
        const msg_bytes = try msgpack.encode(self.allocator, .{ 2, "pty_spawned", params_value });
        defer self.allocator.free(msg_bytes);

        log.info("Sending pty_spawned for pty {}", .{pty_id});

        // Send only to non-plug TUI clients. Plugs receive events via
        // forwardToSubscribedPlugs which filters by subscription.
        for (self.clients.items) |client| {
            if (client.plug_name != null) continue;
            try client.sendData(self.loop, msg_bytes);
        }

        // Forward to subscribed plugs
        self.forwardToSubscribedPlugs("pty_spawned", msg_bytes, null);
    }

    /// Append a new tab to an existing session JSON file.
    fn appendTabToSessionFile(self: *Server, path: []const u8, existing_json: []const u8, pty_id: usize, cwd: []const u8, tab_title: ?[]const u8, validity: i64) !void {
        var parsed = try std.json.parseFromSlice(std.json.Value, self.allocator, existing_json, .{});
        defer parsed.deinit();

        var root = &parsed.value.object;
        const arena = parsed.arena.allocator();

        const tabs_val = root.getPtr("tabs") orelse return error.InvalidSessionFile;
        if (tabs_val.* != .array) return error.InvalidSessionFile;

        // No-op-on-duplicate (parity with the client-side appendTabToSessionFile
        // in src/client.zig on feat/plug-system). If the exact pty_id is
        // already present anywhere in the tab tree, this call is a redundant
        // placement; skip the write. Sits alongside the remap-on-collision
        // logic below, which handles the bounced-server scenario where a new
        // PTY happens to reuse an old, dead PTY's id.
        if (tabsContainPtyId(tabs_val.*, @intCast(pty_id))) |host_tab_id| {
            log.warn(
                "appendTabToSessionFile: pty_id={d} already in session file {s} at tab_id={d} — skipping write",
                .{ pty_id, path, host_tab_id },
            );
            return;
        }

        // Extract and bump counters
        const next_tab_val = root.get("next_tab_id") orelse return error.InvalidSessionFile;
        const next_split_val = root.get("next_split_id") orelse return error.InvalidSessionFile;
        const new_tab_id = if (next_tab_val == .integer) next_tab_val.integer else return error.InvalidSessionFile;
        const new_split_id = if (next_split_val == .integer) next_split_val.integer else return error.InvalidSessionFile;

        // Ensure unique pty_id within the file. When the server bounces,
        // the new PTY can get the same ID as an old tab's PTY. The client's
        // spawn-fallback remap keys by pty_id, so duplicates cause one
        // mapping to clobber the other → two tabs share one PTY → crash.
        var file_pty_id: i64 = @intCast(pty_id);
        for (tabs_val.array.items) |tab_entry| {
            if (tab_entry != .object) continue;
            const root_pane = tab_entry.object.get("root") orelse continue;
            if (root_pane != .object) continue;
            const existing_id = root_pane.object.get("pty_id") orelse continue;
            if (existing_id == .integer and existing_id.integer >= file_pty_id) {
                file_pty_id = existing_id.integer + 1;
            }
        }

        // Build the new tab as a Value tree
        var pane_obj = std.json.ObjectMap.init(arena);
        try pane_obj.put("type", .{ .string = "pane" });
        try pane_obj.put("id", .{ .integer = new_split_id });
        try pane_obj.put("pty_id", .{ .integer = file_pty_id });
        try pane_obj.put("cwd", .{ .string = cwd });

        var tab_obj = std.json.ObjectMap.init(arena);
        try tab_obj.put("id", .{ .integer = new_tab_id });
        if (tab_title) |t| {
            try tab_obj.put("title", .{ .string = t });
        } else {
            try tab_obj.put("title", .null);
        }
        try tab_obj.put("root", .{ .object = pane_obj });
        try tab_obj.put("last_focused_id", .{ .integer = new_split_id });

        // Insert the new tab right of the focused tab, mirroring the Lua
        // break_pane placement policy. The anchor is sourced from the JSON
        // active_tab field (1-based). Missing key, explicit null, and
        // wrong-type reads all normalize to 1 via the helper. Empty tabs
        // array is handled explicitly (std.json.Array.insert at index > len
        // panics, unlike Lua's forgiving table.insert). The target session's
        // active_tab field is NOT modified here — it stays pointing at
        // whatever tab the viewer had focused before the place fired; only
        // the list shape changes.
        const insert_idx = computeSessionFileInsertIndex(root.get("active_tab"), tabs_val.array.items.len);
        try tabs_val.array.insert(insert_idx, .{ .object = tab_obj });

        // Update counters and validity
        try root.put("next_tab_id", .{ .integer = new_tab_id + 1 });
        try root.put("next_split_id", .{ .integer = new_split_id + 1 });
        try root.put("pty_validity", .{ .integer = validity });

        // Serialize back
        const output = try std.fmt.allocPrint(self.allocator, "{f}", .{std.json.fmt(parsed.value, .{})});
        defer self.allocator.free(output);

        const file = try std.fs.createFileAbsolute(path, .{});
        defer file.close();
        try file.writeAll(output);
    }

    /// Compute the 0-based insert index for a new tab in a session file's
    /// `tabs` array, mirroring the Lua break_pane anchor + 1 rule:
    ///   - empty tabs → index 0 (new tab becomes the only tab)
    ///   - otherwise  → clamp(active_tab, 1..len) as the 1-based anchor,
    ///                  converted to 0-based insert index (= clamped),
    ///                  which puts the new tab right of the focused tab.
    ///
    /// active_tab_val is the result of `obj.get("active_tab")`: null when
    /// missing, `.null` when explicitly JSON null, `.integer` when valid,
    /// anything else is treated as an out-of-contract read. Missing / null
    /// / wrong-type / zero / negative all normalize to 1.
    fn computeSessionFileInsertIndex(active_tab_val: ?std.json.Value, tabs_len: usize) usize {
        if (tabs_len == 0) return 0;

        const active_tab: i64 = blk: {
            if (active_tab_val) |v| {
                if (v == .integer) break :blk v.integer;
            }
            // Missing key, explicit .null, or wrong-type → normalize to 1.
            break :blk 1;
        };

        const len_i64: i64 = @intCast(tabs_len);
        // max(1, min(len, active_tab or 1)) with explicit guard for
        // zero/negative active_tab values (which route to 1).
        const floored: i64 = if (active_tab < 1) 1 else active_tab;
        const clamped: i64 = if (floored > len_i64) len_i64 else floored;
        // Convert 1-based anchor to 0-based insert index; insertion at
        // (anchor) in 0-based terms lands right of the 1-based anchor.
        return @intCast(clamped);
    }

    /// Returns the tab id that already hosts pty_id (anywhere in its pane
    /// tree), or null if no tab in `tabs_val` references pty_id. The tab id
    /// is used purely for the diagnostic warn; if the matched tab is missing
    /// an integer id field we return 0 rather than null so the caller can
    /// still detect the duplicate.
    fn tabsContainPtyId(tabs_val: std.json.Value, pty_id: i64) ?i64 {
        if (tabs_val != .array) return null;
        for (tabs_val.array.items) |tab_val| {
            if (!paneSubtreeContainsPtyId(tab_val, pty_id)) continue;
            if (tab_val == .object) {
                if (tab_val.object.get("id")) |id_val| {
                    if (id_val == .integer) return id_val.integer;
                }
            }
            return 0;
        }
        return null;
    }

    fn paneSubtreeContainsPtyId(value: std.json.Value, pty_id: i64) bool {
        switch (value) {
            .object => |obj| {
                if (obj.get("type")) |type_val| {
                    if (type_val == .string and std.mem.eql(u8, type_val.string, "pane")) {
                        if (obj.get("pty_id")) |pid_val| {
                            if (pid_val == .integer and pid_val.integer == pty_id) {
                                return true;
                            }
                        }
                    }
                }
                var it = obj.iterator();
                while (it.next()) |entry| {
                    if (paneSubtreeContainsPtyId(entry.value_ptr.*, pty_id)) return true;
                }
            },
            .array => |arr| {
                for (arr.items) |item| {
                    if (paneSubtreeContainsPtyId(item, pty_id)) return true;
                }
            },
            else => {},
        }
        return false;
    }

    /// Describes a "split into existing tab" placement: the new PTY becomes
    /// a sibling of the targeted pane inside its tab's existing pane tree,
    /// not a brand-new tab. Honored only by the detached-mode write path
    /// (`placePtyInSessionFile`); when a TUI client is attached, the
    /// runtime tiling layer governs placement instead.
    const SplitSpec = struct {
        target_pty_id: usize,
        direction: SplitDirection,
        ratio: f64,
    };

    /// Place a PTY into a session state file so it is discovered on next attach.
    /// Used when no TUI client is connected to receive the pty_spawned event.
    ///
    /// When `split` is non-null and the targeted pty_id is found in the
    /// session file, the new PTY is added as a sibling pane inside the
    /// target's tab — its single-pane root is promoted to a split node.
    /// When `split` is null, the new PTY lands as a new tab (legacy
    /// append-tab semantics; this is the path every existing caller hits).
    /// Target-not-found is intentionally a hard error rather than a silent
    /// fallback to append-tab — falling back masks the bug the split path
    /// was added to fix (the human chose this layout for a reason).
    fn placePtyInSessionFile(
        self: *Server,
        session_name: []const u8,
        pty_id: usize,
        cwd: []const u8,
        tab_title: ?[]const u8,
        split: ?SplitSpec,
    ) !void {
        // Validate session name (no path traversal)
        if (session_name.len == 0) return error.InvalidSessionName;
        if (std.mem.indexOfAny(u8, session_name, "/\\") != null) return error.InvalidSessionName;
        if (std.mem.indexOf(u8, session_name, "..") != null) return error.InvalidSessionName;
        if (std.mem.indexOfScalar(u8, session_name, 0) != null) return error.InvalidSessionName;

        const home = posix.getenv("HOME") orelse return error.NoHomeDirectory;
        const state_dir = try std.fs.path.join(self.allocator, &.{ home, ".local", "state", "prise", "sessions" });
        defer self.allocator.free(state_dir);

        // Ensure directory exists
        std.fs.makeDirAbsolute(state_dir) catch |err| {
            if (err != error.PathAlreadyExists) {
                const parent = std.fs.path.dirname(state_dir) orelse return error.NoHomeDirectory;
                std.fs.makeDirAbsolute(parent) catch |e| {
                    if (e != error.PathAlreadyExists) return e;
                };
                std.fs.makeDirAbsolute(state_dir) catch |e| {
                    if (e != error.PathAlreadyExists) return e;
                };
            }
        };

        const filename = try std.fmt.allocPrint(self.allocator, "{s}.json", .{session_name});
        defer self.allocator.free(filename);

        const path = try std.fs.path.join(self.allocator, &.{ state_dir, filename });
        defer self.allocator.free(path);

        const validity = self.start_time_ms;

        // Try to read existing file
        if (std.fs.openFileAbsolute(path, .{})) |file| {
            defer file.close();
            const existing = try file.readToEndAlloc(self.allocator, 1024 * 1024);
            defer self.allocator.free(existing);
            if (split) |spec| {
                try self.splitTabContainingPtyId(path, existing, pty_id, cwd, spec, validity);
            } else {
                try self.appendTabToSessionFile(path, existing, pty_id, cwd, tab_title, validity);
            }
        } else |_| {
            // No existing session file: split params have no anchor to
            // target, so a split-mode call here is a usage error rather
            // than a "create a new file with one pane" fallback.
            if (split != null) return error.SplitTargetNotFound;
            try self.writeNewSessionFile(path, pty_id, cwd, tab_title, validity);
        }

        log.info("Placed PTY {d} in session file '{s}' (no TUI clients)", .{ pty_id, session_name });
    }

    /// Create a new session file with a single tab containing the given PTY.
    fn writeNewSessionFile(self: *Server, path: []const u8, pty_id: usize, cwd: []const u8, tab_title: ?[]const u8, validity: i64) !void {
        const Pane = struct { type: []const u8, id: u32, pty_id: usize, cwd: []const u8 };
        const Tab = struct { id: u32, title: ?[]const u8, root: Pane, last_focused_id: u32 };
        const Session = struct { pty_validity: i64, tabs: []const Tab, active_tab: u32, next_split_id: u32, next_tab_id: u32 };

        const pane: Pane = .{ .type = "pane", .id = 1, .pty_id = pty_id, .cwd = cwd };
        const tab: Tab = .{ .id = 1, .title = tab_title, .root = pane, .last_focused_id = 1 };
        const tabs = [_]Tab{tab};
        const session: Session = .{ .pty_validity = validity, .tabs = &tabs, .active_tab = 1, .next_split_id = 2, .next_tab_id = 2 };

        const json = try std.fmt.allocPrint(self.allocator, "{f}", .{std.json.fmt(session, .{})});
        defer self.allocator.free(json);

        const file = try std.fs.createFileAbsolute(path, .{});
        defer file.close();
        try file.writeAll(json);
    }

    /// Split the tab containing `spec.target_pty_id` into a two-pane split,
    /// then write the updated session JSON back to disk. Errors with
    /// `error.SplitTargetNotFound` if no tab in the file references
    /// `spec.target_pty_id` — the caller (placePtyInSessionFile) treats
    /// this as a hard failure rather than falling back to append-tab,
    /// because falling back masks the bug the split path was added to fix.
    fn splitTabContainingPtyId(
        self: *Server,
        path: []const u8,
        existing_json: []const u8,
        new_pty_id: usize,
        cwd: []const u8,
        spec: SplitSpec,
        validity: i64,
    ) !void {
        var parsed = try std.json.parseFromSlice(std.json.Value, self.allocator, existing_json, .{});
        defer parsed.deinit();

        const arena = parsed.arena.allocator();
        var root = &parsed.value.object;

        const tabs_val = root.getPtr("tabs") orelse return error.InvalidSessionFile;
        if (tabs_val.* != .array) return error.InvalidSessionFile;

        // Duplicate guard: if the new pty_id is already in the tree (server
        // bounce + spawn-fallback retry), skip the write. Mirrors the
        // append-tab path's no-op-on-duplicate.
        if (tabsContainPtyId(tabs_val.*, @intCast(new_pty_id))) |host_tab_id| {
            log.warn(
                "splitTabContainingPtyId: pty_id={d} already in session file {s} at tab_id={d} — skipping write",
                .{ new_pty_id, path, host_tab_id },
            );
            return;
        }

        const next_split_val = root.get("next_split_id") orelse return error.InvalidSessionFile;
        const next_split_id = if (next_split_val == .integer) next_split_val.integer else return error.InvalidSessionFile;

        // Allocate two ids: one for the split node, one for the new pane
        // child. The original pane keeps its existing id. Counter bump is
        // exactly +2 per split — verified by inline test.
        const split_node_id = next_split_id;
        const new_pane_id = next_split_id + 1;

        // Apply the split in-place on the parsed tree.
        const file_pty_id = try splitTargetPaneInTabs(
            arena,
            tabs_val,
            spec,
            new_pane_id,
            split_node_id,
            cwd,
            new_pty_id,
        );
        _ = file_pty_id;

        try root.put("next_split_id", .{ .integer = next_split_id + 2 });
        try root.put("pty_validity", .{ .integer = validity });

        const output = try std.fmt.allocPrint(self.allocator, "{f}", .{std.json.fmt(parsed.value, .{})});
        defer self.allocator.free(output);

        const file = try std.fs.createFileAbsolute(path, .{});
        defer file.close();
        try file.writeAll(output);
    }

    /// Pure tree mutation: find the tab whose root pane references
    /// `spec.target_pty_id`, replace that root pane with a split node
    /// containing the original pane and a new sibling pane, and update
    /// `last_focused_id` to the new pane (so attach focus lands there).
    /// Returns the file-pty_id assigned to the new pane (after the
    /// bounced-server collision remap), or `error.SplitTargetNotFound` if
    /// no eligible tab is present. Out of scope for v1: targeted pane
    /// already inside an existing split — fails with
    /// `error.SplitTargetIsSplitChild` rather than guessing where to land.
    fn splitTargetPaneInTabs(
        arena: std.mem.Allocator,
        tabs_val: *std.json.Value,
        spec: SplitSpec,
        new_pane_id: i64,
        split_node_id: i64,
        cwd: []const u8,
        new_pty_id: usize,
    ) !i64 {
        const target_i64: i64 = @intCast(spec.target_pty_id);

        for (tabs_val.array.items) |*tab_val| {
            if (tab_val.* != .object) continue;
            var tab_obj = &tab_val.*.object;
            const root_val = tab_obj.getPtr("root") orelse continue;
            if (root_val.* != .object) continue;

            const type_val = root_val.object.get("type") orelse continue;
            if (type_val != .string) continue;

            // v1 only handles tabs whose root is a single pane. If the tab
            // is already split, fail visibly — promotion-into-split is a
            // future task, and falling back to append-tab is the bug.
            if (!std.mem.eql(u8, type_val.string, "pane")) {
                if (paneSubtreeContainsPtyId(root_val.*, target_i64)) {
                    return error.SplitTargetIsSplitChild;
                }
                continue;
            }

            const pid_val = root_val.object.get("pty_id") orelse continue;
            if (pid_val != .integer or pid_val.integer != target_i64) continue;

            // Found the target. Remap the new pty_id past any existing
            // pane pty_ids elsewhere in the file (bounced-server collision
            // guard, parity with appendTabToSessionFile).
            const file_pty_id = remappedFilePtyId(tabs_val.*, new_pty_id);
            try promoteRootPaneToSplit(
                arena,
                tab_obj,
                root_val,
                spec,
                new_pane_id,
                split_node_id,
                cwd,
                file_pty_id,
            );
            return file_pty_id;
        }

        return error.SplitTargetNotFound;
    }

    /// Build the new split node + new pane, replace the tab's root with it,
    /// and update `last_focused_id` to the new pane. Caller has already
    /// confirmed `root_val.*` is a pane node referencing the target pty_id.
    fn promoteRootPaneToSplit(
        arena: std.mem.Allocator,
        tab_obj: *std.json.ObjectMap,
        root_val: *std.json.Value,
        spec: SplitSpec,
        new_pane_id: i64,
        split_node_id: i64,
        cwd: []const u8,
        file_pty_id: i64,
    ) !void {
        const original_pane = root_val.*;

        var new_pane_obj = std.json.ObjectMap.init(arena);
        try new_pane_obj.put("type", .{ .string = "pane" });
        try new_pane_obj.put("id", .{ .integer = new_pane_id });
        try new_pane_obj.put("pty_id", .{ .integer = file_pty_id });
        try new_pane_obj.put("cwd", .{ .string = cwd });

        // ratio belongs on children, not on the split node. On a Row/Column,
        // node.ratio means "size THIS subtree at ratio of parent space"
        // (widget.zig layoutColumnImpl Pass 2), not "split children at ratio."
        // For 50/50: omit ratio on both children so Pass 3 divides space equally
        // among nil-ratio non-intrinsic children. For asymmetric splits: write
        // spec.ratio onto children[0] (original pane) and 1-spec.ratio onto
        // children[1] (new pane). Mirrors tiling.lua:1222-1228.
        const is_equal_split = @abs(spec.ratio - 0.5) < 1e-9;
        var first_child = original_pane;
        if (!is_equal_split) {
            try first_child.object.put("ratio", .{ .float = spec.ratio });
            try new_pane_obj.put("ratio", .{ .float = 1.0 - spec.ratio });
        }

        var children = std.json.Array.init(arena);
        try children.append(first_child);
        try children.append(.{ .object = new_pane_obj });

        var split_obj = std.json.ObjectMap.init(arena);
        try split_obj.put("type", .{ .string = "split" });
        try split_obj.put("split_id", .{ .integer = split_node_id });
        try split_obj.put("direction", .{ .string = spec.direction.toString() });
        try split_obj.put("children", .{ .array = children });

        root_val.* = .{ .object = split_obj };

        // last_focused_id → new pane so the attached client lands there.
        // Stale focus on the original pane is harmless visually, but the
        // human's intent (e.g. "type into planctl watch") wants focus on
        // the freshly-spawned pane.
        try tab_obj.put("last_focused_id", .{ .integer = new_pane_id });
    }

    /// Bounced-server pty_id collision remap: scan all panes in the file
    /// and bump `proposed` past any existing pty_id so the new pane gets a
    /// unique id. Mirrors the inline remap in appendTabToSessionFile.
    fn remappedFilePtyId(tabs_val: std.json.Value, proposed: usize) i64 {
        var file_pty_id: i64 = @intCast(proposed);
        if (tabs_val != .array) return file_pty_id;
        for (tabs_val.array.items) |tab_entry| {
            file_pty_id = bumpPastPanePtyIds(tab_entry, file_pty_id);
        }
        return file_pty_id;
    }

    /// Walk a JSON value (tab, pane, split, or anything in between) and
    /// bump `current` past any pane's pty_id encountered. Pure tree walk;
    /// does not mutate. Used by remappedFilePtyId — split into a helper so
    /// the recursion stays readable inside the 70-line cap.
    fn bumpPastPanePtyIds(value: std.json.Value, current: i64) i64 {
        var max_seen: i64 = current;
        switch (value) {
            .object => |obj| {
                if (obj.get("type")) |type_val| {
                    if (type_val == .string and std.mem.eql(u8, type_val.string, "pane")) {
                        if (obj.get("pty_id")) |pid_val| {
                            if (pid_val == .integer and pid_val.integer >= max_seen) {
                                max_seen = pid_val.integer + 1;
                            }
                        }
                    }
                }
                var it = obj.iterator();
                while (it.next()) |entry| {
                    max_seen = bumpPastPanePtyIds(entry.value_ptr.*, max_seen);
                }
            },
            .array => |arr| {
                for (arr.items) |item| {
                    max_seen = bumpPastPanePtyIds(item, max_seen);
                }
            },
            else => {},
        }
        return max_seen;
    }

    fn sendCwdChanged(self: *Server, pty_instance: *Pty, cwd: []const u8) !void {
        if (cwd.len == 0) return;

        var map_items = try self.allocator.alloc(msgpack.Value.KeyValue, 2);
        defer self.allocator.free(map_items);
        map_items[0] = .{ .key = .{ .string = "pty_id" }, .value = .{ .unsigned = pty_instance.id } };
        map_items[1] = .{ .key = .{ .string = "cwd" }, .value = .{ .string = cwd } };

        const params = msgpack.Value{ .map = map_items };
        const msg_bytes = try msgpack.encode(self.allocator, .{ 2, "cwd_changed", params });
        defer self.allocator.free(msg_bytes);

        log.info("Sending cwd_changed for pty {}: {s}", .{ pty_instance.id, cwd });

        // Send to each client attached to this pty (same pattern as sendRedraw)
        for (self.clients.items) |client| {
            var attached = false;
            for (client.attached_ptys.items) |pid| {
                if (pid == pty_instance.id) {
                    attached = true;
                    break;
                }
            }
            if (attached) {
                try client.sendData(self.loop, msg_bytes);
            }
        }

        // Forward to subscribed plugs
        self.forwardToSubscribedPlugs("cwd_changed", msg_bytes, null);
    }

    fn handleRenameTab(self: *Server, requesting_client: ?*Client, params: msgpack.Value) !msgpack.Value {
        const parsed = parseRenameTabParams(params) catch |err| {
            const message = switch (err) {
                error.InvalidParams => "invalid params",
                error.MissingPtyId => "missing pty_id",
                error.MissingTitle => "missing title",
                error.MissingPtyValidity => "missing pty_validity",
            };
            return msgpack.Value{ .string = try self.allocator.dupe(u8, message) };
        };

        if (parsed.pty_validity != self.start_time_ms) {
            return msgpack.Value{ .string = try self.allocator.dupe(u8, "stale shell environment; open a new shell") };
        }

        const pty_instance = self.ptys.get(parsed.pty_id) orelse {
            return msgpack.Value{ .string = try self.allocator.dupe(u8, "PTY not found") };
        };

        pty_instance.terminal_mutex.lock();
        defer pty_instance.terminal_mutex.unlock();
        try pty_instance.setTitle(parsed.title);

        try self.sendRenameTab(parsed.pty_id, parsed.title, requesting_client);

        return msgpack.Value{ .string = try self.allocator.dupe(u8, "ok") };
    }

    /// Broadcast rename_tab notification to all clients
    fn sendRenameTab(self: *Server, pty_id: usize, title: []const u8, exclude_client: ?*Client) !void {
        var map_items = try self.allocator.alloc(msgpack.Value.KeyValue, 2);
        defer self.allocator.free(map_items);
        map_items[0] = .{ .key = .{ .string = "pty_id" }, .value = .{ .unsigned = pty_id } };
        map_items[1] = .{ .key = .{ .string = "title" }, .value = .{ .string = title } };

        const map_params = msgpack.Value{ .map = map_items };
        const msg_bytes = try msgpack.encode(self.allocator, .{ 2, "rename_tab", map_params });
        defer self.allocator.free(msg_bytes);

        // Skip plug clients — they receive via forwarding below
        for (self.clients.items) |client| {
            if (client.plug_name != null) continue;
            if (exclude_client) |excluded| {
                if (client == excluded) continue;
            }
            try client.sendData(self.loop, msg_bytes);
        }

        // Forward to subscribed plugs (exclude requester to avoid double delivery)
        self.forwardToSubscribedPlugs("rename_tab", msg_bytes, exclude_client);
    }

    fn sendColorQueries(self: *Server, pty_instance: *Pty) !void {
        pty_instance.color_queries_mutex.lock();
        defer pty_instance.color_queries_mutex.unlock();

        const now_ms = std.time.milliTimestamp();

        while (pty_instance.color_queries_len > 0) {
            const query = pty_instance.color_queries_buf[0];

            // Helper to remove first element
            const removeFirst = struct {
                fn remove(p: *Pty) void {
                    const remaining = p.color_queries_len - 1;
                    if (remaining > 0) {
                        std.mem.copyForwards(
                            Pty.ColorQuery,
                            p.color_queries_buf[0..remaining],
                            p.color_queries_buf[1..][0..remaining],
                        );
                    }
                    p.color_queries_len -= 1;
                }
            }.remove;

            // Skip expired queries
            if (now_ms - query.timestamp_ms > LIMITS.COLOR_QUERY_TIMEOUT_MS) {
                removeFirst(pty_instance);
                continue;
            }

            // Build notification params based on target type (include slot for response routing)
            var map_items = try self.allocator.alloc(msgpack.Value.KeyValue, 3);
            defer self.allocator.free(map_items);

            map_items[0] = .{ .key = .{ .string = "pty_id" }, .value = .{ .unsigned = pty_instance.id } };
            map_items[2] = .{ .key = .{ .string = "slot" }, .value = .{ .unsigned = query.response_slot } };

            switch (query.target) {
                .palette => |idx| {
                    map_items[1] = .{ .key = .{ .string = "index" }, .value = .{ .unsigned = idx } };
                },
                .dynamic => |dyn| {
                    const name: []const u8 = switch (dyn) {
                        .foreground => "foreground",
                        .background => "background",
                        .cursor => "cursor",
                        else => {
                            removeFirst(pty_instance);
                            continue;
                        },
                    };
                    map_items[1] = .{ .key = .{ .string = "kind" }, .value = .{ .string = name } };
                },
                .special => {
                    removeFirst(pty_instance);
                    continue;
                },
            }

            const params = msgpack.Value{ .map = map_items };
            const msg_bytes = try msgpack.encode(self.allocator, .{ 2, "color_query", params });
            defer self.allocator.free(msg_bytes);

            // Send to each client attached to this pty
            for (self.clients.items) |client| {
                var attached = false;
                for (client.attached_ptys.items) |pid| {
                    if (pid == pty_instance.id) {
                        attached = true;
                        break;
                    }
                }
                if (attached) {
                    client.sendData(self.loop, msg_bytes) catch |err| {
                        log.err("Failed to send color_query: {}", .{err});
                    };
                }
            }

            pty_instance.color_queries_sent += 1;
            removeFirst(pty_instance);
        }

        // Try to flush any ready responses (lock is already held)
        _ = pty_instance.flushResponsesUnlocked();
    }

    // -- call forward timeout and disconnect cleanup --

    /// Sweep pending forwards for timeouts. Called on a periodic timer.
    fn sweepForwardTimeouts(self: *Server) void {
        const now = std.time.milliTimestamp();
        var to_remove: std.ArrayList(u32) = .empty;
        defer to_remove.deinit(self.allocator);

        var iter = self.pending_forwards.iterator();
        while (iter.next()) |entry| {
            if (now - entry.value_ptr.created_ms > LIMITS.CALL_FORWARD_TIMEOUT_MS) {
                to_remove.append(self.allocator, entry.key_ptr.*) catch continue;
            }
        }

        for (to_remove.items) |fwd_msgid| {
            if (self.pending_forwards.fetchRemove(fwd_msgid)) |entry| {
                const pending = entry.value;
                log.warn("Call forward to plug '{s}' timed out (forward_msgid={})", .{
                    pending.plug_name, fwd_msgid,
                });
                defer self.allocator.free(pending.plug_name);

                // Send timeout error to originator if still connected
                for (self.clients.items) |c| {
                    if (c == pending.originator and !c.closing) {
                        c.sendErrorResponse(self.loop, pending.orig_msgid, error.CallForwardTimeout) catch {};
                        break;
                    }
                }
            }
        }
    }

    fn onSweepTimer(loop: *io.Loop, completion: io.Completion) anyerror!void {
        _ = loop;
        const ctx = completion.userdataCast(SweepTimerContext);
        const server = ctx.server;

        if (server.shutting_down) return;

        server.sweepForwardTimeouts();

        // Re-arm the one-shot timer and track it for shutdown cancellation
        server.sweep_timer_task = try server.loop.timeout(5 * std.time.ns_per_s, .{
            .ptr = ctx,
            .cb = onSweepTimer,
        });
    }

    /// Error out all pending forwards targeting a disconnected plug.
    fn cleanupPlugForwards(self: *Server, plug_client: *Client) void {
        var to_remove: std.ArrayList(u32) = .empty;
        defer to_remove.deinit(self.allocator);

        var iter = self.pending_forwards.iterator();
        while (iter.next()) |entry| {
            if (plug_client.plug_name) |name| {
                if (std.mem.eql(u8, entry.value_ptr.plug_name, name)) {
                    to_remove.append(self.allocator, entry.key_ptr.*) catch continue;
                }
            }
        }

        for (to_remove.items) |fwd_msgid| {
            if (self.pending_forwards.fetchRemove(fwd_msgid)) |entry| {
                const pending = entry.value;
                defer self.allocator.free(pending.plug_name);
                for (self.clients.items) |c| {
                    if (c == pending.originator and !c.closing) {
                        c.sendErrorResponse(self.loop, pending.orig_msgid, error.PlugDisconnected) catch {};
                        break;
                    }
                }
            }
        }
    }

    /// Silently remove all pending forwards from a disconnecting TUI client.
    fn cleanupOriginatorForwards(self: *Server, originator: *Client) void {
        var to_remove: std.ArrayList(u32) = .empty;
        defer to_remove.deinit(self.allocator);

        var iter = self.pending_forwards.iterator();
        while (iter.next()) |entry| {
            if (entry.value_ptr.originator == originator) {
                to_remove.append(self.allocator, entry.key_ptr.*) catch continue;
            }
        }

        for (to_remove.items) |fwd_msgid| {
            if (self.pending_forwards.fetchRemove(fwd_msgid)) |entry| {
                self.allocator.free(entry.value.plug_name);
            }
        }
    }

    /// Synchronously reap one managed plug after SIGTERM has already been sent.
    /// Polls waitpid(NOHANG) for up to PLUG_SHUTDOWN_GRACE_MS, then escalates
    /// to SIGKILL and keeps polling.
    fn reapManagedPlugSync(mp: *ManagedPlug) void {
        const pid = mp.pid orelse return;
        const poll_interval_ms: u64 = 20;
        const grace_iterations: u64 = LIMITS.PLUG_SHUTDOWN_GRACE_MS / poll_interval_ms;

        for (0..grace_iterations) |_| {
            const res = posix.waitpid(pid, posix.W.NOHANG);
            if (res.pid != 0) {
                log.info("plug.{s} pid {} exited on shutdown (status {})", .{ mp.name, pid, res.status });
                mp.pid = null;
                return;
            }
            std.Thread.sleep(poll_interval_ms * std.time.ns_per_ms);
        }

        log.warn(
            "plug.{s} pid {} ignored SIGTERM after {}ms, sending SIGKILL",
            .{ mp.name, pid, LIMITS.PLUG_SHUTDOWN_GRACE_MS },
        );
        posix.kill(pid, posix.SIG.KILL) catch {};
        while (true) {
            const res = posix.waitpid(pid, posix.W.NOHANG);
            if (res.pid != 0) {
                log.info("plug.{s} pid {} reaped after SIGKILL (status {})", .{ mp.name, pid, res.status });
                mp.pid = null;
                return;
            }
            std.Thread.sleep(poll_interval_ms * std.time.ns_per_ms);
        }
    }

    /// Tear down all managed plugs as part of server shutdown. SIGTERMs each
    /// plug and cancels its async waitpid_task / restart_timer in one pass
    /// (so plugs shut down in parallel), then synchronously reaps each one in
    /// a second pass. Without the synchronous reap the server's own process
    /// can exit before its plugs have, leaving them reparented to launchd as
    /// orphans.
    fn shutdownManagedPlugs(self: *Server) void {
        // Pass 1: signal every plug and cancel async tasks. Setting
        // killed_by_server BEFORE the signal prevents onPlugExit from
        // scheduling a restart if it races us.
        for (self.managed_plugs.items) |*mp| {
            if (mp.pid) |pid| {
                mp.killed_by_server = true;
                posix.kill(pid, posix.SIG.TERM) catch {};
            }
            if (mp.waitpid_task) |*task| {
                task.cancel(self.loop) catch {};
                mp.waitpid_task = null;
            }
            if (mp.restart_timer_task) |*task| {
                task.cancel(self.loop) catch {};
                mp.restart_timer_task = null;
            }
            if (mp.restart_ctx) |ctx| {
                self.allocator.free(ctx.plug_name);
                self.allocator.destroy(ctx);
                mp.restart_ctx = null;
            }
        }

        // Pass 2: synchronously reap. Bounded per plug by
        // PLUG_SHUTDOWN_GRACE_MS + SIGKILL.
        for (self.managed_plugs.items) |*mp| {
            reapManagedPlugSync(mp);
        }
    }

    fn shutdown(self: *Server) void {
        std.log.info("Shutting down server...", .{});

        // Gate restart timer callbacks before killing children
        self.shutting_down = true;

        self.shutdownManagedPlugs();

        // Cancel sweep timer before freeing its context
        if (self.sweep_timer_task) |*task| {
            task.cancel(self.loop) catch {};
            self.sweep_timer_task = null;
        }
        if (self.sweep_timer_ctx) |ctx| {
            self.allocator.destroy(ctx);
            self.sweep_timer_ctx = null;
        }

        // Error out remaining pending forwards
        var fwd_iter = self.pending_forwards.iterator();
        while (fwd_iter.next()) |entry| {
            self.allocator.free(entry.value_ptr.plug_name);
        }
        self.pending_forwards.clearRetainingCapacity();

        // Stop accepting
        self.accepting = false;
        if (self.accept_task) |*task| {
            task.cancel(self.loop) catch {};
            self.accept_task = null;
        }

        // Cancel the deadline-sweep timer so the loop can drain. The
        // sweep callback also gates re-arm on `self.accepting`, so a
        // race-fire here is safely a no-op.
        if (self.pending_sweep_timer) |*task| {
            task.cancel(self.loop) catch {};
            self.pending_sweep_timer = null;
        }

        // Drain in-flight broker-RPC requests with best-effort
        // `broker_timeout` replies BEFORE we tear down clients. Once
        // a CLI client is removed, the loop can no longer queue a
        // Response on its fd; replying first gives the CLI a clean
        // exit instead of a 2s deadline-sweep wait that never fires.
        // Send failures are logged and the drain continues.
        self.drainPendingForShutdown();

        // Close all clients
        while (self.clients.items.len > 0) {
            const client = self.clients.items[0];
            self.removeClient(client);
        }

        // Cancel signal watcher
        self.loop.cancelByFd(self.signal_pipe_fds[0]);

        // Signal all PTYs to stop and cancel their IO
        var it = self.ptys.valueIterator();
        while (it.next()) |pty_instance| {
            pty_instance.*.running.store(false, .seq_cst);
            pty_instance.*.cancelPendingIO(self.loop);
            _ = posix.write(pty_instance.*.exit_pipe_fds[1], "q") catch {};
        }
    }

    fn onSignal(loop: *io.Loop, completion: io.Completion) anyerror!void {
        const self = completion.userdataCast(Server);

        switch (completion.result) {
            .read => |n| {
                if (n == 0) return;
                // Drain
                var buf: [128]u8 = undefined;
                while (true) {
                    _ = posix.read(self.signal_pipe_fds[0], &buf) catch |err| {
                        if (err == error.WouldBlock) break;
                        break;
                    };
                }

                self.shutdown();
            },
            .err => |err| {
                std.log.err("Signal pipe error: {}", .{err});
            },
            else => {},
        }
        _ = loop;
    }

    fn onRenderTimer(loop: *io.Loop, completion: io.Completion) anyerror!void {
        _ = loop;
        const pty_instance = completion.userdataCast(Pty);
        pty_instance.render_timer = null;
        if (!pty_instance.running.load(.seq_cst)) return;
        const server: *Server = @ptrCast(@alignCast(pty_instance.server_ptr));
        server.renderFrame(pty_instance);
    }

    fn onPtyDirty(loop: *io.Loop, completion: io.Completion) anyerror!void {
        const pty_instance = completion.userdataCast(Pty);
        const server: *Server = @ptrCast(@alignCast(pty_instance.server_ptr));

        switch (completion.result) {
            .read => |n| {
                if (n == 0) return;

                // Check if this is an exit signal from the read thread
                if (pty_instance.dirty_signal_buf[0] == 'e') {
                    // Process has exited - read thread already reaped it
                    server.handleProcessExit(loop, pty_instance);
                    return;
                }

                // Drain pipe (there may be more signals)
                var buf: [128]u8 = undefined;
                var saw_exit = false;
                while (true) {
                    const bytes = posix.read(pty_instance.pipe_fds[0], &buf) catch |err| {
                        if (err == error.WouldBlock) break;
                        break;
                    };
                    // Check for exit signal in drained data
                    for (buf[0..bytes]) |b| {
                        if (b == 'e') saw_exit = true;
                    }
                }

                if (saw_exit) {
                    server.handleProcessExit(loop, pty_instance);
                    return;
                }

                const now = std.time.milliTimestamp();
                // 8ms (~120fps) balances responsiveness with efficiency. Lower values
                // increase CPU usage with diminishing perceptual benefit; higher values
                // cause visible lag during fast output (e.g., `cat large_file`).
                // See ARCHITECTURE.md "Event-Oriented Frame Scheduler".
                const FRAME_TIME = 8;

                if (now - pty_instance.last_render_time >= FRAME_TIME) {
                    server.renderFrame(pty_instance);
                } else if (pty_instance.render_timer == null) {
                    const delay = FRAME_TIME - (now - pty_instance.last_render_time);
                    // Make sure delay is positive
                    const safe_delay = if (delay < 0) 0 else delay;
                    pty_instance.render_timer = try loop.timeout(@as(u64, @intCast(safe_delay)) * std.time.ns_per_ms, .{
                        .ptr = pty_instance,
                        .cb = onRenderTimer,
                    });
                }

                // Re-arm only if still running
                if (pty_instance.running.load(.seq_cst)) {
                    _ = try loop.read(pty_instance.pipe_fds[0], &pty_instance.dirty_signal_buf, .{
                        .ptr = pty_instance,
                        .cb = onPtyDirty,
                    });
                }
            },
            .err => |err| {
                std.log.err("Pty dirty pipe error: {}", .{err});
            },
            else => {},
        }
    }

    fn handleProcessExit(self: *Server, loop: *io.Loop, pty_instance: *Pty) void {
        const status = pty_instance.exit_status.load(.seq_cst);
        log.info("PTY {} process exited with status {}", .{ pty_instance.id, status });

        // Send exit notification to clients
        self.sendPtyExited(pty_instance.id, status) catch |err| {
            std.log.err("Failed to send pty_exited: {}", .{err});
        };

        // Render final frame
        self.renderFrame(pty_instance);

        // Remove from server's pty map
        _ = self.ptys.fetchRemove(pty_instance.id);

        // Cancel pending IO and join read thread
        pty_instance.cancelPendingIO(loop);

        if (pty_instance.read_thread) |thread| {
            thread.join();
            pty_instance.read_thread = null;
        }

        // Free PTY resources
        pty_instance.process.close();
        posix.close(pty_instance.pipe_fds[0]);
        posix.close(pty_instance.pipe_fds[1]);
        posix.close(pty_instance.exit_pipe_fds[0]);
        posix.close(pty_instance.exit_pipe_fds[1]);
        pty_instance.terminal.deinit(self.allocator);
        pty_instance.render_state.deinit(self.allocator);
        pty_instance.clients.deinit(self.allocator);
        pty_instance.title.deinit(self.allocator);
        pty_instance.cwd.deinit(self.allocator);
        self.allocator.destroy(pty_instance);
    }

    /// Read ~/.config/prise/prise.toml and spawn one managed plug per
    /// `[[plug]]` block. ENOENT → no-op (server starts clean). Any other read
    /// or parse error is FATAL: log and propagate so the caller exits.
    /// Per-plug spawn failure is non-fatal: log a single WARN and continue.
    fn loadConfigPlugs(self: *Server) !void {
        const home = std.process.getEnvVarOwned(self.allocator, "HOME") catch |err| {
            log.err("FATAL: cannot resolve HOME for prise.toml: {s}", .{@errorName(err)});
            return err;
        };
        defer self.allocator.free(home);

        const path = try std.fs.path.join(self.allocator, &.{ home, ".config", "prise", "prise.toml" });
        defer self.allocator.free(path);

        const content = std.fs.cwd().readFileAlloc(self.allocator, path, 1 * 1024 * 1024) catch |err| {
            if (err == error.FileNotFound) {
                log.info("No prise.toml at {s} — starting with no config-declared plugs", .{path});
                return;
            }
            log.err("FATAL: cannot read {s}: {s}", .{ path, @errorName(err) });
            return err;
        };
        defer self.allocator.free(content);

        const decls = plug_config.parsePlugConfig(self.allocator, content) catch |err| {
            log.err("FATAL: parse error in {s}: {s}", .{ path, @errorName(err) });
            return err;
        };
        defer plug_config.deinitDecls(self.allocator, decls);

        for (decls) |decl| {
            self.spawnConfigDecl(decl) catch |err| {
                const cmd0 = if (decl.cmd.len > 0) decl.cmd[0] else "";
                log.warn(
                    "plug spawn failed name={s} cmd0={s} error={s}",
                    .{ decl.name, cmd0, @errorName(err) },
                );
            };
        }
    }

    /// Spawn a single config-declared plug. On error, the helper makes sure
    /// no half-built ManagedPlug is left in the list — the caller logs WARN
    /// and continues to the next decl.
    fn spawnConfigDecl(self: *Server, decl: plug_config.PlugDecl) !void {
        // Dupe cmd (decl is owned by deinitDecls — we need our own copy for
        // ManagedPlug's lifetime, which exceeds the parsed decls).
        const owned_cmd = try self.dupePlugCmdFromStrings(decl.cmd);
        errdefer self.freePlugCmd(owned_cmd);

        try self.spawnManagedPlug(
            decl.name,
            owned_cmd,
            decl.restart,
            decl.restart_delay_ms,
            .config,
        );
    }

    /// Dupe a slice of owned strings into fresh server-allocated slices.
    /// Sibling of `dupePlugCmd` for the non-msgpack path.
    fn dupePlugCmdFromStrings(self: *Server, cmd: []const []const u8) ![]const []const u8 {
        const owned = try self.allocator.alloc([]const u8, cmd.len);
        var i: usize = 0;
        errdefer {
            for (owned[0..i]) |arg| self.allocator.free(arg);
            self.allocator.free(owned);
        }
        for (cmd) |arg| {
            owned[i] = try self.allocator.dupe(u8, arg);
            i += 1;
        }
        return owned;
    }
};

fn buildPtyEntry(allocator: std.mem.Allocator, pty_instance: *const Pty) ![]msgpack.Value.KeyValue {
    const entries = try allocator.alloc(msgpack.Value.KeyValue, 4);
    @memset(entries, .{ .key = .nil, .value = .nil });
    errdefer {
        for (entries) |kv| {
            kv.key.deinit(allocator);
            kv.value.deinit(allocator);
        }
        allocator.free(entries);
    }

    entries[0].key = .{ .string = try allocator.dupe(u8, "id") };
    entries[0].value = .{ .unsigned = @intCast(pty_instance.id) };
    entries[1].key = .{ .string = try allocator.dupe(u8, "cwd") };
    entries[1].value = .{ .string = try allocator.dupe(u8, pty_instance.cwd.items) };
    entries[2].key = .{ .string = try allocator.dupe(u8, "title") };
    entries[2].value = .{ .string = try allocator.dupe(u8, pty_instance.title.items) };
    entries[3].key = .{ .string = try allocator.dupe(u8, "attached_client_count") };
    entries[3].value = .{ .unsigned = @intCast(pty_instance.clients.items.len) };

    return entries;
}

fn buildPlugEntry(allocator: std.mem.Allocator, mp: *const ManagedPlug) ![]msgpack.Value.KeyValue {
    const field_count: usize = 5;
    const entries = try allocator.alloc(msgpack.Value.KeyValue, field_count);
    @memset(entries, .{ .key = .nil, .value = .nil });
    errdefer {
        for (entries) |kv| {
            kv.key.deinit(allocator);
            kv.value.deinit(allocator);
        }
        allocator.free(entries);
    }

    entries[0].key = .{ .string = try allocator.dupe(u8, "name") };
    entries[0].value = .{ .string = try allocator.dupe(u8, mp.name) };

    entries[1].key = .{ .string = try allocator.dupe(u8, "registered") };
    entries[1].value = .{ .boolean = mp.registered };

    entries[2].key = .{ .string = try allocator.dupe(u8, "pid") };
    entries[2].value = if (mp.pid) |pid|
        .{ .integer = @intCast(pid) }
    else
        .nil;

    entries[3].key = .{ .string = try allocator.dupe(u8, "restart_count") };
    entries[3].value = .{ .unsigned = mp.restart_count };

    entries[4].key = .{ .string = try allocator.dupe(u8, "restart") };
    entries[4].value = .{ .boolean = mp.restart };

    return entries;
}

pub fn startServer(allocator: std.mem.Allocator, socket_path: []const u8) !void {
    std.log.info("Starting server on {s}", .{socket_path});

    crash_context.init(.server, main.version);
    defer crash_context.deinit();
    crash_context.setSocketPath(socket_path);
    crash_context.record("server start", .{});

    var loop = try io.Loop.init(allocator);
    defer loop.deinit();
    errdefer crash_context.writeBundle("server startup failed", null, null);

    // Check if socket exists and if a server is already running
    if (std.fs.accessAbsolute(socket_path, .{})) {
        // Socket exists - test if server is alive
        const test_fd = posix.socket(posix.AF.UNIX, posix.SOCK.STREAM | posix.SOCK.CLOEXEC, 0) catch |err| {
            std.log.err("Failed to create test socket: {}", .{err});
            return err;
        };
        defer posix.close(test_fd);

        var addr: posix.sockaddr.un = undefined;
        addr.family = posix.AF.UNIX;
        @memcpy(addr.path[0..socket_path.len], socket_path);
        addr.path[socket_path.len] = 0;

        if (posix.connect(test_fd, @ptrCast(&addr), @sizeOf(posix.sockaddr.un))) {
            // Connection succeeded - server is already running
            std.log.err("Server is already running on {s}", .{socket_path});
            return error.AddressInUse;
        } else |err| {
            if (err == error.ConnectionRefused or err == error.FileNotFound) {
                // Stale socket
                std.log.info("Removing stale socket", .{});
                posix.unlink(socket_path) catch {};
            } else {
                std.log.err("Failed to test socket: {}", .{err});
                crash_context.record("socket probe failed: {s}", .{@errorName(err)});
                return err;
            }
        }
    } else |err| {
        if (err != error.FileNotFound) {
            crash_context.record("socket access error: {s}", .{@errorName(err)});
            return err;
        }
        // Socket doesn't exist, continue
    }

    // Create socket
    const listen_fd = try posix.socket(posix.AF.UNIX, posix.SOCK.STREAM | posix.SOCK.CLOEXEC, 0);
    errdefer posix.close(listen_fd);

    // Bind to socket path
    var addr: posix.sockaddr.un = undefined;
    addr.family = posix.AF.UNIX;
    @memcpy(addr.path[0..socket_path.len], socket_path);
    addr.path[socket_path.len] = 0;

    try posix.bind(listen_fd, @ptrCast(&addr), @sizeOf(posix.sockaddr.un));

    // Listen
    try posix.listen(listen_fd, 128);

    // Create signal pipe
    const signal_pipe_fds = try posix.pipe2(.{ .NONBLOCK = true, .CLOEXEC = true });
    signal_write_fd = signal_pipe_fds[1];

    // Ignore SIGPIPE. The upstream io layer (kqueue.zig completeSend) calls
    // posix.send(fd, buf, 0) with no MSG_NOSIGNAL flag. On macOS, writing to
    // a broken socket delivers SIGPIPE — default action is silent process
    // termination (no panic handler, no crash bundle, no error). With plugs,
    // forwardToSubscribedPlugs writes to plug sockets that can go stale when
    // a plug process dies and restarts. Ignoring SIGPIPE makes posix.send
    // return EPIPE instead, which the io layer catches and returns as an
    // .err completion. forwardToSubscribedPlugs already has a catch block
    // that logs the error and continues.
    const ignore: posix.Sigaction = .{
        .handler = .{ .handler = posix.SIG.IGN },
        .mask = posix.sigemptyset(),
        .flags = 0,
    };
    posix.sigaction(posix.SIG.PIPE, &ignore, null);

    var sa: posix.Sigaction = .{
        .handler = .{ .handler = signalHandler },
        .mask = posix.sigemptyset(),
        .flags = 0,
    };
    posix.sigaction(posix.SIG.INT, &sa, null);
    posix.sigaction(posix.SIG.TERM, &sa, null);

    var server: Server = .{
        .allocator = allocator,
        .loop = &loop,
        .listen_fd = listen_fd,
        .socket_path = socket_path,
        .clients = std.ArrayList(*Client).empty,
        .ptys = std.AutoHashMap(usize, *Pty).init(allocator),
        .pending = std.AutoHashMap(usize, PendingBreak).init(allocator),
        .signal_pipe_fds = signal_pipe_fds,
        .start_time_ms = std.time.milliTimestamp(),
        .plugs = std.StringHashMap(*Client).init(allocator),
        .pending_forwards = std.AutoHashMap(u32, PendingForward).init(allocator),
    };
    crash_context.setPtyValidity(server.start_time_ms);
    defer {
        posix.close(signal_pipe_fds[0]);
        posix.close(signal_pipe_fds[1]);
        for (server.clients.items) |client| {
            posix.close(client.fd);
            client.attached_ptys.deinit(allocator);
            // client.style_cache.deinit();
            allocator.destroy(client);
        }
        server.clients.deinit(allocator);
        server.ptys.deinit();
        server.pending.deinit();
        server.plugs.deinit();
        server.pending_forwards.deinit();
        if (server.sweep_timer_ctx) |ctx| {
            allocator.destroy(ctx);
        }
        for (server.managed_plugs.items) |*mp| {
            mp.deinit(allocator);
        }
        server.managed_plugs.deinit(allocator);
    }

    // Load and spawn config-declared plugs from ~/.config/prise/prise.toml.
    // Runs after Server struct is constructed and before the accept enqueue,
    // so loop.waitpid registrations made by spawnManagedPlug ride alongside
    // the same pre-`loop.run` enqueues already used for accept and signals.
    // Failure to read/parse the config is FATAL — launchd's ThrottleInterval
    // is the circuit breaker for malformed config.
    try server.loadConfigPlugs();

    // Start accepting connections
    crash_context.record("server accepting connections", .{});
    server.accept_task = try loop.accept(listen_fd, .{
        .ptr = &server,
        .cb = Server.onAccept,
    });

    // Start sweep timer for call forward timeouts
    const sweep_ctx = try allocator.create(SweepTimerContext);
    sweep_ctx.* = .{ .server = &server };
    server.sweep_timer_ctx = sweep_ctx;
    server.sweep_timer_task = try loop.timeout(5 * std.time.ns_per_s, .{
        .ptr = sweep_ctx,
        .cb = Server.onSweepTimer,
    });

    // Register signal watcher
    _ = try loop.read(signal_pipe_fds[0], &server.signal_buf, .{
        .ptr = &server,
        .cb = Server.onSignal,
    });

    // Arm the deadline-sweep timer: re-arms itself from its callback
    // at `LIMITS.PENDING_SWEEP_MS` cadence to retire any expired
    // pending broker-RPC entries (e.g. break_pane requests whose
    // broker never replied).
    try server.armPendingSweepTimer();

    // Run until server decides to exit
    try loop.run(.until_done);

    // Block signals during thread cleanup to prevent EINTR interrupting joins
    var block_mask = posix.sigemptyset();
    posix.sigaddset(&block_mask, posix.SIG.INT);
    posix.sigaddset(&block_mask, posix.SIG.TERM);
    posix.sigprocmask(posix.SIG.BLOCK, &block_mask, null);

    // Join all PTY threads before exiting
    var it = server.ptys.valueIterator();
    while (it.next()) |pty_instance| {
        pty_instance.*.joinAndFree(allocator);
    }
    server.ptys.clearRetainingCapacity();

    // Cleanup
    posix.close(listen_fd);
    posix.unlink(socket_path) catch {};
}

/// Compare a ManagedPlug's owned cmd slices against parsed msgpack values.
fn plugCmdMatchesParsed(cmd: []const []const u8, parsed_cmd: []const msgpack.Value) bool {
    if (cmd.len != parsed_cmd.len) return false;
    for (cmd, parsed_cmd) |owned, val| {
        const parsed_str = switch (val) {
            .string => |s| s,
            else => return false,
        };
        if (!std.mem.eql(u8, owned, parsed_str)) return false;
    }
    return true;
}

test "server lifecycle - shutdown when no clients" {
    const testing = std.testing;

    var loop = try io.Loop.init(testing.allocator);
    defer loop.deinit();

    var server: Server = .{
        .allocator = testing.allocator,
        .loop = &loop,
        .listen_fd = 100,
        .socket_path = "/tmp/test.sock",
        .clients = std.ArrayList(*Client).empty,
        .ptys = std.AutoHashMap(usize, *Pty).init(testing.allocator),
        .pending = std.AutoHashMap(usize, PendingBreak).init(testing.allocator),
        .exit_on_idle = true,
        .signal_pipe_fds = undefined,
        .plugs = std.StringHashMap(*Client).init(testing.allocator),
        .pending_forwards = std.AutoHashMap(u32, PendingForward).init(testing.allocator),
    };
    defer server.clients.deinit(testing.allocator);
    defer server.ptys.deinit();
    defer server.pending.deinit();

    server.accept_task = try loop.accept(100, .{
        .ptr = &server,
        .cb = Server.onAccept,
    });

    try testing.expect(server.accepting);
    try testing.expect(server.shouldExit());

    try server.checkExit();

    try testing.expect(!server.accepting);
    try testing.expect(server.accept_task == null);
}

test "server lifecycle - accept client connection" {
    const testing = std.testing;

    var loop = try io.Loop.init(testing.allocator);
    defer loop.deinit();

    var server: Server = .{
        .allocator = testing.allocator,
        .loop = &loop,
        .listen_fd = 100,
        .socket_path = "/tmp/test.sock",
        .clients = std.ArrayList(*Client).empty,
        .ptys = std.AutoHashMap(usize, *Pty).init(testing.allocator),
        .pending = std.AutoHashMap(usize, PendingBreak).init(testing.allocator),
        .signal_pipe_fds = undefined,
        .plugs = std.StringHashMap(*Client).init(testing.allocator),
        .pending_forwards = std.AutoHashMap(u32, PendingForward).init(testing.allocator),
    };
    defer {
        for (server.clients.items) |client| {
            testing.allocator.destroy(client);
        }
        server.clients.deinit(testing.allocator);
        server.ptys.deinit();
        server.pending.deinit();
    }

    server.accept_task = try loop.accept(100, .{
        .ptr = &server,
        .cb = Server.onAccept,
    });

    try loop.completeAccept(100);
    try loop.run(.once);

    try testing.expectEqual(@as(usize, 1), server.clients.items.len);
    try testing.expect(server.accepting);
}

test "server lifecycle - client disconnect triggers shutdown" {
    const testing = std.testing;

    var loop = try io.Loop.init(testing.allocator);
    defer loop.deinit();

    var server: Server = .{
        .allocator = testing.allocator,
        .loop = &loop,
        .listen_fd = 100,
        .socket_path = "/tmp/test.sock",
        .clients = std.ArrayList(*Client).empty,
        .ptys = std.AutoHashMap(usize, *Pty).init(testing.allocator),
        .pending = std.AutoHashMap(usize, PendingBreak).init(testing.allocator),
        .exit_on_idle = true,
        .signal_pipe_fds = undefined,
        .plugs = std.StringHashMap(*Client).init(testing.allocator),
        .pending_forwards = std.AutoHashMap(u32, PendingForward).init(testing.allocator),
    };
    defer {
        for (server.clients.items) |client| {
            testing.allocator.destroy(client);
        }
        server.clients.deinit(testing.allocator);
        server.ptys.deinit();
        server.pending.deinit();
    }

    server.accept_task = try loop.accept(100, .{
        .ptr = &server,
        .cb = Server.onAccept,
    });

    try loop.completeAccept(100);
    try loop.run(.once);

    try testing.expectEqual(@as(usize, 1), server.clients.items.len);
    const client_fd = server.clients.items[0].fd;

    try loop.completeRecv(client_fd, "");
    try loop.run(.once);

    try testing.expectEqual(@as(usize, 0), server.clients.items.len);
    try testing.expect(!server.accepting);
}

test "server lifecycle - multiple clients" {
    const testing = std.testing;

    var loop = try io.Loop.init(testing.allocator);
    defer loop.deinit();

    var server: Server = .{
        .allocator = testing.allocator,
        .loop = &loop,
        .listen_fd = 100,
        .socket_path = "/tmp/test.sock",
        .clients = std.ArrayList(*Client).empty,
        .ptys = std.AutoHashMap(usize, *Pty).init(testing.allocator),
        .pending = std.AutoHashMap(usize, PendingBreak).init(testing.allocator),
        .exit_on_idle = true,
        .signal_pipe_fds = undefined,
        .plugs = std.StringHashMap(*Client).init(testing.allocator),
        .pending_forwards = std.AutoHashMap(u32, PendingForward).init(testing.allocator),
    };
    defer {
        for (server.clients.items) |client| {
            testing.allocator.destroy(client);
        }
        server.clients.deinit(testing.allocator);
        server.ptys.deinit();
        server.pending.deinit();
    }

    server.accept_task = try loop.accept(100, .{
        .ptr = &server,
        .cb = Server.onAccept,
    });

    try loop.completeAccept(100);
    try loop.run(.once);
    try testing.expectEqual(@as(usize, 1), server.clients.items.len);

    try loop.completeAccept(100);
    try loop.run(.once);
    try testing.expectEqual(@as(usize, 2), server.clients.items.len);

    try loop.completeAccept(100);
    try loop.run(.once);
    try testing.expectEqual(@as(usize, 3), server.clients.items.len);

    const client1_fd = server.clients.items[0].fd;
    const client2_fd = server.clients.items[1].fd;
    const client3_fd = server.clients.items[2].fd;

    try loop.completeRecv(client2_fd, "");
    try loop.run(.until_done);
    try testing.expectEqual(@as(usize, 2), server.clients.items.len);

    try loop.completeRecv(client1_fd, "");
    try loop.run(.until_done);
    try testing.expectEqual(@as(usize, 1), server.clients.items.len);

    try loop.completeRecv(client3_fd, "");
    try loop.run(.until_done);
    try testing.expectEqual(@as(usize, 0), server.clients.items.len);
    try testing.expect(!server.accepting);
}

test "server lifecycle - recv error triggers disconnect" {
    const testing = std.testing;

    var loop = try io.Loop.init(testing.allocator);
    defer loop.deinit();

    var server: Server = .{
        .allocator = testing.allocator,
        .loop = &loop,
        .listen_fd = 100,
        .socket_path = "/tmp/test.sock",
        .clients = std.ArrayList(*Client).empty,
        .ptys = std.AutoHashMap(usize, *Pty).init(testing.allocator),
        .pending = std.AutoHashMap(usize, PendingBreak).init(testing.allocator),
        .exit_on_idle = true,
        .signal_pipe_fds = undefined,
        .plugs = std.StringHashMap(*Client).init(testing.allocator),
        .pending_forwards = std.AutoHashMap(u32, PendingForward).init(testing.allocator),
    };
    defer {
        for (server.clients.items) |client| {
            testing.allocator.destroy(client);
        }
        server.clients.deinit(testing.allocator);
        server.ptys.deinit();
        server.pending.deinit();
    }

    server.accept_task = try loop.accept(100, .{
        .ptr = &server,
        .cb = Server.onAccept,
    });

    try loop.completeAccept(100);
    try loop.run(.once);
    try testing.expectEqual(@as(usize, 1), server.clients.items.len);
    const client_fd = server.clients.items[0].fd;

    try loop.completeWithError(client_fd, error.ConnectionReset);
    try loop.run(.once);
    try testing.expectEqual(@as(usize, 0), server.clients.items.len);
    try testing.expect(!server.accepting);
}

test "parseSpawnPtyParams" {
    const testing = std.testing;

    // Empty params - defaults
    const p1 = Server.parseSpawnPtyParams(.{ .map = &.{} });
    try testing.expectEqual(@as(u16, 24), p1.size.ws_row);
    try testing.expectEqual(@as(u16, 80), p1.size.ws_col);
    try testing.expectEqual(false, p1.attach);
    try testing.expectEqual(@as(?[]const u8, null), p1.cwd);
    try testing.expectEqual(@as(?[]const u8, null), p1.session);
    try testing.expectEqual(@as(?[]const u8, null), p1.tab);
    try testing.expectEqual(@as(?[]const u8, null), p1.title);

    // Full params
    var params = [_]msgpack.Value.KeyValue{
        .{ .key = .{ .string = "rows" }, .value = .{ .unsigned = 40 } },
        .{ .key = .{ .string = "cols" }, .value = .{ .unsigned = 100 } },
        .{ .key = .{ .string = "attach" }, .value = .{ .boolean = true } },
    };
    const p2 = Server.parseSpawnPtyParams(.{ .map = &params });
    try testing.expectEqual(@as(u16, 40), p2.size.ws_row);
    try testing.expectEqual(@as(u16, 100), p2.size.ws_col);
    try testing.expectEqual(true, p2.attach);
    try testing.expectEqual(@as(?[]const u8, null), p2.cwd);

    // With cwd param
    var params_with_cwd = [_]msgpack.Value.KeyValue{
        .{ .key = .{ .string = "rows" }, .value = .{ .unsigned = 30 } },
        .{ .key = .{ .string = "cols" }, .value = .{ .unsigned = 120 } },
        .{ .key = .{ .string = "cwd" }, .value = .{ .string = "/tmp" } },
    };
    const p3 = Server.parseSpawnPtyParams(.{ .map = &params_with_cwd });
    try testing.expectEqual(@as(u16, 30), p3.size.ws_row);
    try testing.expectEqual(@as(u16, 120), p3.size.ws_col);
    try testing.expectEqualStrings("/tmp", p3.cwd.?);

    // With placement fields
    var params_with_placement = [_]msgpack.Value.KeyValue{
        .{ .key = .{ .string = "rows" }, .value = .{ .unsigned = 24 } },
        .{ .key = .{ .string = "cols" }, .value = .{ .unsigned = 80 } },
        .{ .key = .{ .string = "session" }, .value = .{ .string = "work" } },
        .{ .key = .{ .string = "tab" }, .value = .{ .string = "new" } },
        .{ .key = .{ .string = "title" }, .value = .{ .string = "claude" } },
    };
    const p4 = Server.parseSpawnPtyParams(.{ .map = &params_with_placement });
    try testing.expectEqualStrings("work", p4.session.?);
    try testing.expectEqualStrings("new", p4.tab.?);
    try testing.expectEqualStrings("claude", p4.title.?);

    // With cmd param
    var params_with_cmd = [_]msgpack.Value.KeyValue{
        .{ .key = .{ .string = "rows" }, .value = .{ .unsigned = 30 } },
        .{ .key = .{ .string = "cols" }, .value = .{ .unsigned = 120 } },
        .{ .key = .{ .string = "cmd" }, .value = .{ .string = "echo hello" } },
    };
    const p5 = Server.parseSpawnPtyParams(.{ .map = &params_with_cmd });
    try testing.expectEqualStrings("echo hello", p5.cmd.?);

    // Without cmd param - null
    try testing.expectEqual(@as(?[]const u8, null), p1.cmd);

    // With argv param - direct exec path
    var argv_values = [_]msgpack.Value{
        .{ .string = "prisectl-ui" },
        .{ .string = "plug-status" },
    };
    var params_with_argv = [_]msgpack.Value.KeyValue{
        .{ .key = .{ .string = "rows" }, .value = .{ .unsigned = 30 } },
        .{ .key = .{ .string = "cols" }, .value = .{ .unsigned = 120 } },
        .{ .key = .{ .string = "argv" }, .value = .{ .array = &argv_values } },
    };
    const p_argv = Server.parseSpawnPtyParams(.{ .map = &params_with_argv });
    try testing.expect(p_argv.argv != null);
    try testing.expectEqual(@as(usize, 2), p_argv.argv.?.len);
    try testing.expectEqualStrings("prisectl-ui", p_argv.argv.?[0].string);
    try testing.expectEqualStrings("plug-status", p_argv.argv.?[1].string);

    // Without argv param - null
    try testing.expectEqual(@as(?[]const msgpack.Value, null), p1.argv);

    // Defaults for split-related fields when missing.
    try testing.expectEqual(@as(?usize, null), p1.split_target_pty_id);
    try testing.expectEqual(Server.SplitDirection.col, p1.split_direction);
    try testing.expectEqual(@as(f64, 0.5), p1.split_ratio);

    // With split params: col / row direction, integer + float ratio.
    var params_with_split_col = [_]msgpack.Value.KeyValue{
        .{ .key = .{ .string = "split_target_pty_id" }, .value = .{ .unsigned = 7 } },
        .{ .key = .{ .string = "split_direction" }, .value = .{ .string = "col" } },
        .{ .key = .{ .string = "split_ratio" }, .value = .{ .float = 0.7 } },
    };
    const p7 = Server.parseSpawnPtyParams(.{ .map = &params_with_split_col });
    try testing.expectEqual(@as(?usize, 7), p7.split_target_pty_id);
    try testing.expectEqual(Server.SplitDirection.col, p7.split_direction);
    try testing.expectEqual(@as(f64, 0.7), p7.split_ratio);

    var params_with_split_row = [_]msgpack.Value.KeyValue{
        .{ .key = .{ .string = "split_target_pty_id" }, .value = .{ .integer = 9 } },
        .{ .key = .{ .string = "split_direction" }, .value = .{ .string = "row" } },
    };
    const p8 = Server.parseSpawnPtyParams(.{ .map = &params_with_split_row });
    try testing.expectEqual(@as(?usize, 9), p8.split_target_pty_id);
    try testing.expectEqual(Server.SplitDirection.row, p8.split_direction);
    // Ratio defaults to 0.5 when omitted.
    try testing.expectEqual(@as(f64, 0.5), p8.split_ratio);

    // Reject path: wrong-type / negative split_target_pty_id leaves it null,
    // wrong-type direction stays at default .col, integer ratio coerces.
    var params_split_rejects = [_]msgpack.Value.KeyValue{
        .{ .key = .{ .string = "split_target_pty_id" }, .value = .{ .integer = -3 } },
        .{ .key = .{ .string = "split_direction" }, .value = .{ .string = "diagonal" } },
        .{ .key = .{ .string = "split_ratio" }, .value = .{ .unsigned = 1 } },
    };
    const p9 = Server.parseSpawnPtyParams(.{ .map = &params_split_rejects });
    try testing.expectEqual(@as(?usize, null), p9.split_target_pty_id);
    try testing.expectEqual(Server.SplitDirection.col, p9.split_direction);
    try testing.expectEqual(@as(f64, 1.0), p9.split_ratio);

    // Non-map params (nil) - all defaults
    const p10 = Server.parseSpawnPtyParams(.nil);
    try testing.expectEqual(@as(u16, 24), p10.size.ws_row);
    try testing.expectEqual(@as(u16, 80), p10.size.ws_col);
    try testing.expectEqual(false, p10.attach);
    try testing.expectEqual(@as(?[]const u8, null), p10.cwd);

    // Wrong value types silently ignored - fall back to defaults
    var params_wrong_types = [_]msgpack.Value.KeyValue{
        .{ .key = .{ .string = "rows" }, .value = .{ .string = "hello" } },
        .{ .key = .{ .string = "cols" }, .value = .{ .boolean = true } },
        .{ .key = .{ .string = "attach" }, .value = .{ .unsigned = 1 } },
        .{ .key = .{ .string = "cwd" }, .value = .{ .unsigned = 42 } },
        .{ .key = .{ .string = "cmd" }, .value = .{ .boolean = false } },
    };
    const p11 = Server.parseSpawnPtyParams(.{ .map = &params_wrong_types });
    try testing.expectEqual(@as(u16, 24), p11.size.ws_row);
    try testing.expectEqual(@as(u16, 80), p11.size.ws_col);
    try testing.expectEqual(false, p11.attach);
    try testing.expectEqual(@as(?[]const u8, null), p11.cwd);
    try testing.expectEqual(@as(?[]const u8, null), p11.cmd);

    // Unknown keys ignored
    var params_unknown = [_]msgpack.Value.KeyValue{
        .{ .key = .{ .string = "rows" }, .value = .{ .unsigned = 50 } },
        .{ .key = .{ .string = "bogus" }, .value = .{ .string = "ignored" } },
    };
    const p12 = Server.parseSpawnPtyParams(.{ .map = &params_unknown });
    try testing.expectEqual(@as(u16, 50), p12.size.ws_row);

    // env param - array of strings
    var env_vals = [_]msgpack.Value{
        .{ .string = "PATH=/usr/bin" },
        .{ .string = "HOME=/tmp" },
    };
    var params_with_env = [_]msgpack.Value.KeyValue{
        .{ .key = .{ .string = "env" }, .value = .{ .array = &env_vals } },
    };
    const p13 = Server.parseSpawnPtyParams(.{ .map = &params_with_env });
    try testing.expect(p13.env != null);
    try testing.expectEqual(@as(usize, 2), p13.env.?.len);
}

test "prepareSpawnEnv" {
    const testing = std.testing;
    var env_map = std.process.EnvMap.init(testing.allocator);
    defer env_map.deinit();

    try env_map.put("EXISTING", "value");

    var list = try Server.prepareSpawnEnv(testing.allocator, &env_map);
    defer {
        for (list.items) |item| testing.allocator.free(item);
        list.deinit(testing.allocator);
    }

    var found_term = false;
    var found_colorterm = false;
    var found_existing = false;

    for (list.items) |item| {
        if (std.mem.startsWith(u8, item, "TERM=")) found_term = true;
        if (std.mem.startsWith(u8, item, "COLORTERM=")) found_colorterm = true;
        if (std.mem.startsWith(u8, item, "EXISTING=")) found_existing = true;
    }

    try testing.expect(found_term);
    try testing.expect(found_colorterm);
    try testing.expect(found_existing);
}

fn initRenameTestServer(allocator: std.mem.Allocator, loop: *io.Loop, start_time_ms: i64) Server {
    return .{
        .allocator = allocator,
        .loop = loop,
        .listen_fd = -1,
        .socket_path = "/tmp/test.sock",
        .clients = std.ArrayList(*Client).empty,
        .ptys = std.AutoHashMap(usize, *Pty).init(allocator),
        .signal_pipe_fds = .{ -1, -1 },
        .start_time_ms = start_time_ms,
        .pending = std.AutoHashMap(usize, PendingBreak).init(allocator),
        .pending_forwards = std.AutoHashMap(u32, PendingForward).init(allocator),
    };
}

fn initRenameTestPty(allocator: std.mem.Allocator, id: usize) Pty {
    var pty_instance: Pty = undefined;
    pty_instance.allocator = allocator;
    pty_instance.id = id;
    pty_instance.clients = std.ArrayList(*Client).empty;
    pty_instance.running = std.atomic.Value(bool).init(true);
    pty_instance.title = .empty;
    pty_instance.cwd = .empty;
    pty_instance.terminal_mutex = .{};
    return pty_instance;
}

test "appendPriseSpawnEnv includes pty validity" {
    const testing = std.testing;
    var loop: io.Loop = undefined;
    var server = initRenameTestServer(testing.allocator, &loop, 1234);
    defer {
        server.clients.deinit(testing.allocator);
        server.ptys.deinit();
    }

    var env_list = std.ArrayList([]const u8).empty;
    defer {
        for (env_list.items) |item| testing.allocator.free(item);
        env_list.deinit(testing.allocator);
    }

    try server.appendPriseSpawnEnv(&env_list, 42);

    var found_pty = false;
    var found_validity = false;
    var found_socket = false;

    for (env_list.items) |item| {
        if (std.mem.eql(u8, item, "PRISE_PTY=42")) found_pty = true;
        if (std.mem.eql(u8, item, "PRISE_PTY_VALIDITY=1234")) found_validity = true;
        if (std.mem.eql(u8, item, "PRISE_SOCKET=/tmp/test.sock")) found_socket = true;
    }

    try testing.expect(found_pty);
    try testing.expect(found_validity);
    try testing.expect(found_socket);
}

test "handleRenameTab validates pty validity and updates title" {
    const testing = std.testing;
    var loop: io.Loop = undefined;
    var server = initRenameTestServer(testing.allocator, &loop, 777);
    defer {
        server.clients.deinit(testing.allocator);
        server.ptys.deinit();
    }

    var pty_instance = initRenameTestPty(testing.allocator, 42);
    defer {
        pty_instance.title.deinit(testing.allocator);
        pty_instance.cwd.deinit(testing.allocator);
        pty_instance.clients.deinit(testing.allocator);
    }

    try server.ptys.put(pty_instance.id, &pty_instance);

    var valid_params = [_]msgpack.Value.KeyValue{
        .{ .key = .{ .string = "pty_id" }, .value = .{ .unsigned = 42 } },
        .{ .key = .{ .string = "title" }, .value = .{ .string = "renamed" } },
        .{ .key = .{ .string = "pty_validity" }, .value = .{ .integer = 777 } },
    };
    const ok = try server.handleRenameTab(null, .{ .map = &valid_params });
    defer ok.deinit(testing.allocator);
    try testing.expect(ok == .string);
    try testing.expectEqualStrings("ok", ok.string);
    try testing.expectEqualStrings("renamed", pty_instance.title.items);

    var stale_params = [_]msgpack.Value.KeyValue{
        .{ .key = .{ .string = "pty_id" }, .value = .{ .unsigned = 42 } },
        .{ .key = .{ .string = "title" }, .value = .{ .string = "wrong" } },
        .{ .key = .{ .string = "pty_validity" }, .value = .{ .integer = 1 } },
    };
    const stale = try server.handleRenameTab(null, .{ .map = &stale_params });
    defer stale.deinit(testing.allocator);
    try testing.expect(stale == .string);
    try testing.expectEqualStrings("stale shell environment; open a new shell", stale.string);

    _ = server.ptys.remove(pty_instance.id);

    var missing_params = [_]msgpack.Value.KeyValue{
        .{ .key = .{ .string = "pty_id" }, .value = .{ .unsigned = 42 } },
        .{ .key = .{ .string = "title" }, .value = .{ .string = "missing" } },
        .{ .key = .{ .string = "pty_validity" }, .value = .{ .integer = 777 } },
    };
    const missing = try server.handleRenameTab(null, .{ .map = &missing_params });
    defer missing.deinit(testing.allocator);
    try testing.expect(missing == .string);
    try testing.expectEqualStrings("PTY not found", missing.string);
}

test "parseBreakPaneParams - valid params" {
    const testing = std.testing;

    var params = [_]msgpack.Value.KeyValue{
        .{ .key = .{ .string = "pty_id" }, .value = .{ .unsigned = 42 } },
        .{ .key = .{ .string = "focus" }, .value = .{ .boolean = true } },
    };
    const parsed = try Server.parseBreakPaneParams(.{ .map = &params });
    try testing.expectEqual(@as(u32, 42), parsed.pty_id);
    try testing.expectEqual(true, parsed.focus);

    // pty_id can also arrive as a positive integer
    var int_params = [_]msgpack.Value.KeyValue{
        .{ .key = .{ .string = "pty_id" }, .value = .{ .integer = 7 } },
        .{ .key = .{ .string = "focus" }, .value = .{ .boolean = false } },
    };
    const int_parsed = try Server.parseBreakPaneParams(.{ .map = &int_params });
    try testing.expectEqual(@as(u32, 7), int_parsed.pty_id);
    try testing.expectEqual(false, int_parsed.focus);
}

test "parseBreakPaneParams - missing pty_id" {
    const testing = std.testing;

    var params = [_]msgpack.Value.KeyValue{
        .{ .key = .{ .string = "focus" }, .value = .{ .boolean = true } },
    };
    try testing.expectError(error.MalformedParams, Server.parseBreakPaneParams(.{ .map = &params }));
}

test "parseBreakPaneParams - missing focus" {
    const testing = std.testing;

    var params = [_]msgpack.Value.KeyValue{
        .{ .key = .{ .string = "pty_id" }, .value = .{ .unsigned = 1 } },
    };
    try testing.expectError(error.MalformedParams, Server.parseBreakPaneParams(.{ .map = &params }));
}

test "parseBreakPaneParams - wrong type for focus" {
    const testing = std.testing;

    var params = [_]msgpack.Value.KeyValue{
        .{ .key = .{ .string = "pty_id" }, .value = .{ .unsigned = 1 } },
        .{ .key = .{ .string = "focus" }, .value = .{ .string = "true" } },
    };
    try testing.expectError(error.MalformedParams, Server.parseBreakPaneParams(.{ .map = &params }));
}

test "parseBreakPaneParams - wrong type for pty_id" {
    const testing = std.testing;

    var params = [_]msgpack.Value.KeyValue{
        .{ .key = .{ .string = "pty_id" }, .value = .{ .string = "1" } },
        .{ .key = .{ .string = "focus" }, .value = .{ .boolean = false } },
    };
    try testing.expectError(error.MalformedParams, Server.parseBreakPaneParams(.{ .map = &params }));
}

test "parseBreakPaneParams - non-map root" {
    const testing = std.testing;

    var arr = [_]msgpack.Value{ .{ .unsigned = 1 }, .{ .boolean = true } };
    try testing.expectError(error.MalformedParams, Server.parseBreakPaneParams(.{ .array = &arr }));
}

test "parseAttachPtyParams" {
    const testing = std.testing;

    var valid_args = [_]msgpack.Value{.{ .unsigned = 42 }};
    const result = try Server.parseAttachPtyParams(.{ .array = &valid_args });
    try testing.expectEqual(@as(usize, 42), result.pty_id);
    try testing.expectEqual(key_encode.OptionAsAlt.false, result.macos_option_as_alt);

    var valid_args_with_opt = [_]msgpack.Value{ .{ .unsigned = 42 }, .{ .string = "left" } };
    const result2 = try Server.parseAttachPtyParams(.{ .array = &valid_args_with_opt });
    try testing.expectEqual(@as(usize, 42), result2.pty_id);
    try testing.expectEqual(key_encode.OptionAsAlt.left, result2.macos_option_as_alt);

    var invalid_args = [_]msgpack.Value{};
    try testing.expectError(error.InvalidParams, Server.parseAttachPtyParams(.{ .array = &invalid_args }));
}

test "parseWritePtyParams" {
    const testing = std.testing;

    var valid_args = [_]msgpack.Value{
        .{ .unsigned = 42 },
        .{ .binary = "hello" },
    };
    const args = try Server.parseWritePtyParams(.{ .array = &valid_args });
    try testing.expectEqual(@as(usize, 42), args.id);
    try testing.expectEqualStrings("hello", args.data);
}

test "parseResizePtyParams" {
    const testing = std.testing;

    var valid_args = [_]msgpack.Value{
        .{ .unsigned = 42 },
        .{ .unsigned = 50 },
        .{ .unsigned = 80 },
    };
    const args = try Server.parseResizePtyParams(.{ .array = &valid_args });
    try testing.expectEqual(@as(usize, 42), args.id);
    try testing.expectEqual(@as(u16, 50), args.rows);
    try testing.expectEqual(@as(u16, 80), args.cols);
    try testing.expectEqual(@as(u16, 0), args.x_pixel);
    try testing.expectEqual(@as(u16, 0), args.y_pixel);

    var pixel_args = [_]msgpack.Value{
        .{ .unsigned = 42 },
        .{ .unsigned = 50 },
        .{ .unsigned = 80 },
        .{ .unsigned = 800 },
        .{ .unsigned = 600 },
    };
    const p_args = try Server.parseResizePtyParams(.{ .array = &pixel_args });
    try testing.expectEqual(@as(usize, 42), p_args.id);
    try testing.expectEqual(@as(u16, 50), p_args.rows);
    try testing.expectEqual(@as(u16, 80), p_args.cols);
    try testing.expectEqual(@as(u16, 800), p_args.x_pixel);
    try testing.expectEqual(@as(u16, 600), p_args.y_pixel);
}

test "buildRedrawMessageFromPty" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var pty_inst: Pty = .{
        .id = 1,
        .process = .{ .master = -1, .slave = -1, .pid = 0 },
        .clients = std.ArrayList(*Client).empty,
        .running = std.atomic.Value(bool).init(true),
        .terminal = try ghostty_vt.Terminal.init(allocator, .{ .cols = 80, .rows = 24 }),
        .allocator = allocator,
        .title = std.ArrayList(u8).empty,
        .title_dirty = false,
        .cwd = std.ArrayList(u8).empty,
        .cwd_dirty = false,
        .pipe_fds = undefined,
        .exit_pipe_fds = undefined,
        .render_state = .empty,
        .server_ptr = undefined,
    };
    defer {
        pty_inst.terminal.deinit(allocator);
        pty_inst.render_state.deinit(allocator);
        pty_inst.clients.deinit(allocator);
        pty_inst.title.deinit(allocator);
        pty_inst.cwd.deinit(allocator);
    }

    const msg = try buildRedrawMessageFromPty(allocator, &pty_inst, .full);
    defer allocator.free(msg);

    try testing.expect(msg.len > 0);

    const value = try msgpack.decode(allocator, msg);
    defer value.deinit(allocator);
    try testing.expect(value == .array);
}

test "style optimization" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var pty_inst: Pty = .{
        .id = 1,
        .process = .{ .master = -1, .slave = -1, .pid = 0 },
        .clients = std.ArrayList(*Client).empty,
        .running = std.atomic.Value(bool).init(true),
        .terminal = try ghostty_vt.Terminal.init(allocator, .{ .cols = 10, .rows = 5 }),
        .allocator = allocator,
        .title = std.ArrayList(u8).empty,
        .title_dirty = false,
        .cwd = std.ArrayList(u8).empty,
        .cwd_dirty = false,
        .pipe_fds = undefined,
        .exit_pipe_fds = undefined,
        .render_state = .empty,
        .server_ptr = undefined,
    };
    defer {
        pty_inst.terminal.deinit(allocator);
        pty_inst.render_state.deinit(allocator);
        pty_inst.clients.deinit(allocator);
        pty_inst.title.deinit(allocator);
        pty_inst.cwd.deinit(allocator);
    }

    const handler = vt_handler.Handler.init(&pty_inst.terminal);
    var stream = vt_handler.Stream.initAlloc(allocator, handler);
    defer stream.deinit();

    // Row 0: A (Default), B (Red), C (Default)
    stream.nextSlice(&[_]u8{'A'});
    stream.nextSlice("\x1b[31m");
    stream.nextSlice(&[_]u8{'B'});
    stream.nextSlice("\x1b[0m");
    stream.nextSlice(&[_]u8{'C'});

    // Newline to start Row 1
    stream.nextSlice("\r\n");

    // D (Red) - testing switching from Default (C) to Red (D) across rows/cells
    stream.nextSlice("\x1b[31m");
    stream.nextSlice(&[_]u8{'D'});

    const msg = try buildRedrawMessageFromPty(allocator, &pty_inst, .full);
    defer allocator.free(msg);

    const value = try msgpack.decode(allocator, msg);
    defer value.deinit(allocator);

    // Verify results by inspecting msgpack events
    const events = value.array[2].array;
    var style_def_red: ?u32 = null;
    var found_row0 = false;
    var found_row1 = false;

    for (events) |evt_val| {
        const name = evt_val.array[0].string;
        const args = evt_val.array[1].array;

        if (std.mem.eql(u8, name, "style")) {
            const id = @as(u32, @intCast(args[0].unsigned));
            const attrs_map = args[1].map;
            for (attrs_map) |kv| {
                if (std.mem.eql(u8, kv.key.string, "fg") and kv.value.unsigned == 0xFF0000) {
                    style_def_red = id;
                }
                if (std.mem.eql(u8, kv.key.string, "fg_idx") and kv.value.unsigned == 1) {
                    style_def_red = id;
                }
            }
        } else if (std.mem.eql(u8, name, "write")) {
            const row = @as(u16, @intCast(args[1].unsigned));
            const cells_arr = args[3].array;

            if (row == 0) {
                found_row0 = true;
                // Cell 1 should be B with red style
                const cell1 = cells_arr[1].array;
                try testing.expectEqualStrings("B", cell1[0].string);
                if (cell1.len > 1 and cell1[1] != .nil) {
                    const sid = @as(u32, @intCast(cell1[1].unsigned));
                    try testing.expectEqual(style_def_red.?, sid);
                }
            }
            if (row == 1) {
                found_row1 = true;
                // Cell 0 should be D with red style
                const cell0 = cells_arr[0].array;
                try testing.expectEqualStrings("D", cell0[0].string);
                if (cell0.len > 1 and cell0[1] != .nil) {
                    const sid = @as(u32, @intCast(cell0[1].unsigned));
                    try testing.expectEqual(style_def_red.?, sid);
                }
            }
        }
    }

    try testing.expect(style_def_red != null);
    try testing.expect(found_row0);
    try testing.expect(found_row1);
}

// Test helper: decode the most recent Response sent on `fd` (if any)
// from the mock Loop's pending send queue. Returns null when no send
// is queued. Caller owns the returned message and must deinit.
fn findPendingSendOnFd(allocator: std.mem.Allocator, loop: *io.Loop, fd: posix.fd_t) !?rpc.Message {
    var it = loop.pending.iterator();
    while (it.next()) |entry| {
        if (entry.value_ptr.kind == .send and entry.value_ptr.fd == fd) {
            return try rpc.decodeMessage(allocator, entry.value_ptr.buf);
        }
    }
    return null;
}

test "parseBreakPaneReplyParams - happy paths and edge cases" {
    const testing = std.testing;

    var ok_params = [_]msgpack.Value.KeyValue{
        .{ .key = .{ .string = "request_id" }, .value = .{ .unsigned = 5 } },
        .{ .key = .{ .string = "ok" }, .value = .{ .boolean = true } },
    };
    const ok_parsed = try Server.parseBreakPaneReplyParams(.{ .map = &ok_params });
    try testing.expectEqual(@as(usize, 5), ok_parsed.request_id);
    try testing.expectEqual(true, ok_parsed.ok);
    try testing.expectEqual(@as(?[]const u8, null), ok_parsed.reason);

    var refuse_params = [_]msgpack.Value.KeyValue{
        .{ .key = .{ .string = "request_id" }, .value = .{ .unsigned = 5 } },
        .{ .key = .{ .string = "ok" }, .value = .{ .boolean = false } },
        .{ .key = .{ .string = "reason" }, .value = .{ .string = "solo_pane" } },
    };
    const refuse_parsed = try Server.parseBreakPaneReplyParams(.{ .map = &refuse_params });
    try testing.expectEqual(false, refuse_parsed.ok);
    try testing.expectEqualStrings("solo_pane", refuse_parsed.reason.?);

    var no_id = [_]msgpack.Value.KeyValue{
        .{ .key = .{ .string = "ok" }, .value = .{ .boolean = true } },
    };
    try testing.expectError(error.MalformedParams, Server.parseBreakPaneReplyParams(.{ .map = &no_id }));

    var no_ok = [_]msgpack.Value.KeyValue{
        .{ .key = .{ .string = "request_id" }, .value = .{ .unsigned = 1 } },
    };
    try testing.expectError(error.MalformedParams, Server.parseBreakPaneReplyParams(.{ .map = &no_ok }));

    var bad_ok = [_]msgpack.Value.KeyValue{
        .{ .key = .{ .string = "request_id" }, .value = .{ .unsigned = 1 } },
        .{ .key = .{ .string = "ok" }, .value = .{ .string = "true" } },
    };
    try testing.expectError(error.MalformedParams, Server.parseBreakPaneReplyParams(.{ .map = &bad_ok }));
}

test "handleBreakPaneReply - non-ok refusal sends Response with reason" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var loop = try io.Loop.init(allocator);
    defer loop.deinit();

    var server: Server = .{
        .allocator = allocator,
        .loop = &loop,
        .listen_fd = 100,
        .socket_path = "/tmp/test.sock",
        .clients = std.ArrayList(*Client).empty,
        .ptys = std.AutoHashMap(usize, *Pty).init(allocator),
        .pending = std.AutoHashMap(usize, PendingBreak).init(allocator),
        .pending_forwards = std.AutoHashMap(u32, PendingForward).init(allocator),
        .signal_pipe_fds = undefined,
    };
    defer {
        for (server.clients.items) |c| {
            if (c.send_buffer) |buf| allocator.free(buf);
            for (c.send_queue.items) |buf| allocator.free(buf);
            c.send_queue.deinit(allocator);
            c.attached_ptys.deinit(allocator);
            c.msg_buffer.deinit(allocator);
            allocator.destroy(c);
        }
        server.clients.deinit(allocator);
        server.ptys.deinit();
        server.pending.deinit();
    }

    const cli = try allocator.create(Client);
    cli.* = .{
        .fd = 300,
        .id = 99,
        .server = &server,
        .msg_buffer = std.ArrayList(u8).empty,
        .send_queue = std.ArrayList([]u8).empty,
        .attached_ptys = std.ArrayList(usize).empty,
    };
    try server.clients.append(allocator, cli);

    // Broker client (id=1) — must thread through `handleBreakPaneReply`
    // so the new identity guard sees a matching `broker_id`.
    const broker = try allocator.create(Client);
    broker.* = .{
        .fd = 301,
        .id = 1,
        .server = &server,
        .msg_buffer = std.ArrayList(u8).empty,
        .send_queue = std.ArrayList([]u8).empty,
        .attached_ptys = std.ArrayList(usize).empty,
    };
    try server.clients.append(allocator, broker);

    // Pre-populate a pending entry as if handleBreakPane wrote it.
    try server.pending.put(0, .{
        .cli_msgid = 77,
        .cli_client = cli,
        .broker_id = 1,
        .deadline_ts = std.time.milliTimestamp() + 2000,
        .pty_id = 7,
        .focus = false,
    });

    // Build the broker's reply notification payload.
    var reply_params = [_]msgpack.Value.KeyValue{
        .{ .key = .{ .string = "request_id" }, .value = .{ .unsigned = 0 } },
        .{ .key = .{ .string = "ok" }, .value = .{ .boolean = false } },
        .{ .key = .{ .string = "reason" }, .value = .{ .string = "solo_pane" } },
    };
    try server.handleBreakPaneReply(broker, .{ .method = "break_pane_reply", .params = .{ .map = &reply_params } });

    // Pending dropped, Response queued to CLI fd.
    try testing.expectEqual(@as(usize, 0), server.pending.count());
    const msg_opt = try findPendingSendOnFd(allocator, &loop, 300);
    try testing.expect(msg_opt != null);
    const msg = msg_opt.?;
    defer msg.deinit(allocator);

    try testing.expect(msg == .response);
    try testing.expectEqual(@as(u32, 77), msg.response.msgid);
    try testing.expect(msg.response.err == null);
    try testing.expect(msg.response.result == .map);

    var got_ok = false;
    var got_reason = false;
    for (msg.response.result.map) |kv| {
        if (std.mem.eql(u8, kv.key.string, "ok")) {
            try testing.expect(kv.value.boolean == false);
            got_ok = true;
        } else if (std.mem.eql(u8, kv.key.string, "reason")) {
            try testing.expectEqualStrings("solo_pane", kv.value.string);
            got_reason = true;
        }
    }
    try testing.expect(got_ok);
    try testing.expect(got_reason);
}

test "handleBreakPaneReply - unknown request_id silently dropped" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var loop = try io.Loop.init(allocator);
    defer loop.deinit();

    var server: Server = .{
        .allocator = allocator,
        .loop = &loop,
        .listen_fd = 100,
        .socket_path = "/tmp/test.sock",
        .clients = std.ArrayList(*Client).empty,
        .ptys = std.AutoHashMap(usize, *Pty).init(allocator),
        .pending = std.AutoHashMap(usize, PendingBreak).init(allocator),
        .pending_forwards = std.AutoHashMap(u32, PendingForward).init(allocator),
        .signal_pipe_fds = undefined,
    };
    defer {
        for (server.clients.items) |c| {
            if (c.send_buffer) |buf| allocator.free(buf);
            for (c.send_queue.items) |buf| allocator.free(buf);
            c.send_queue.deinit(allocator);
            c.attached_ptys.deinit(allocator);
            c.msg_buffer.deinit(allocator);
            allocator.destroy(c);
        }
        server.clients.deinit(allocator);
        server.ptys.deinit();
        server.pending.deinit();
    }

    // A sender client to thread through the call. With no pending
    // entry registered the early-return fires before any identity check.
    const sender = try allocator.create(Client);
    sender.* = .{
        .fd = 301,
        .id = 1,
        .server = &server,
        .msg_buffer = std.ArrayList(u8).empty,
        .send_queue = std.ArrayList([]u8).empty,
        .attached_ptys = std.ArrayList(usize).empty,
    };
    try server.clients.append(allocator, sender);

    // Spurious reply for a request_id that was never registered.
    var reply_params = [_]msgpack.Value.KeyValue{
        .{ .key = .{ .string = "request_id" }, .value = .{ .unsigned = 999 } },
        .{ .key = .{ .string = "ok" }, .value = .{ .boolean = true } },
    };
    try server.handleBreakPaneReply(sender, .{ .method = "break_pane_reply", .params = .{ .map = &reply_params } });

    // No pending entries created; no spurious sends queued.
    try testing.expectEqual(@as(usize, 0), server.pending.count());
    var any_send = false;
    var it = loop.pending.iterator();
    while (it.next()) |entry| {
        if (entry.value_ptr.kind == .send) any_send = true;
    }
    try testing.expect(!any_send);
}

test "handleBreakPaneReply - malformed payload silently dropped" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var loop = try io.Loop.init(allocator);
    defer loop.deinit();

    var server: Server = .{
        .allocator = allocator,
        .loop = &loop,
        .listen_fd = 100,
        .socket_path = "/tmp/test.sock",
        .clients = std.ArrayList(*Client).empty,
        .ptys = std.AutoHashMap(usize, *Pty).init(allocator),
        .pending = std.AutoHashMap(usize, PendingBreak).init(allocator),
        .pending_forwards = std.AutoHashMap(u32, PendingForward).init(allocator),
        .signal_pipe_fds = undefined,
    };
    defer {
        for (server.clients.items) |c| {
            if (c.send_buffer) |buf| allocator.free(buf);
            for (c.send_queue.items) |buf| allocator.free(buf);
            c.send_queue.deinit(allocator);
            c.attached_ptys.deinit(allocator);
            c.msg_buffer.deinit(allocator);
            allocator.destroy(c);
        }
        server.clients.deinit(allocator);
        server.ptys.deinit();
        server.pending.deinit();
    }

    // Sender client — parse-failure path returns before identity check.
    const sender = try allocator.create(Client);
    sender.* = .{
        .fd = 301,
        .id = 1,
        .server = &server,
        .msg_buffer = std.ArrayList(u8).empty,
        .send_queue = std.ArrayList([]u8).empty,
        .attached_ptys = std.ArrayList(usize).empty,
    };
    try server.clients.append(allocator, sender);

    // Missing `ok` field — handler must not panic, must not send.
    var bad = [_]msgpack.Value.KeyValue{
        .{ .key = .{ .string = "request_id" }, .value = .{ .unsigned = 0 } },
    };
    try server.handleBreakPaneReply(sender, .{ .method = "break_pane_reply", .params = .{ .map = &bad } });
    try testing.expectEqual(@as(usize, 0), server.pending.count());
}

test "handleBreakPaneReply - ok path broadcasts to non-broker attached clients" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var loop = try io.Loop.init(allocator);
    defer loop.deinit();

    var server: Server = .{
        .allocator = allocator,
        .loop = &loop,
        .listen_fd = 100,
        .socket_path = "/tmp/test.sock",
        .clients = std.ArrayList(*Client).empty,
        .ptys = std.AutoHashMap(usize, *Pty).init(allocator),
        .pending = std.AutoHashMap(usize, PendingBreak).init(allocator),
        .pending_forwards = std.AutoHashMap(u32, PendingForward).init(allocator),
        .signal_pipe_fds = undefined,
    };
    defer {
        for (server.clients.items) |c| {
            if (c.send_buffer) |buf| allocator.free(buf);
            for (c.send_queue.items) |buf| allocator.free(buf);
            c.send_queue.deinit(allocator);
            c.attached_ptys.deinit(allocator);
            c.msg_buffer.deinit(allocator);
            allocator.destroy(c);
        }
        server.clients.deinit(allocator);
        server.ptys.deinit();
        server.pending.deinit();
    }

    // Three attached clients: id=1 (broker, fd=201), id=2 (fd=202), id=3 (fd=203).
    const ids = [_]usize{ 1, 2, 3 };
    for (ids) |client_id| {
        const c = try allocator.create(Client);
        c.* = .{
            .fd = @intCast(200 + @as(i32, @intCast(client_id))),
            .id = client_id,
            .server = &server,
            .msg_buffer = std.ArrayList(u8).empty,
            .send_queue = std.ArrayList([]u8).empty,
            .attached_ptys = std.ArrayList(usize).empty,
        };
        try c.attached_ptys.append(allocator, 5);
        try server.clients.append(allocator, c);
    }

    // CLI client (originator), unattached (acts as the requester).
    const cli = try allocator.create(Client);
    cli.* = .{
        .fd = 300,
        .id = 99,
        .server = &server,
        .msg_buffer = std.ArrayList(u8).empty,
        .send_queue = std.ArrayList([]u8).empty,
        .attached_ptys = std.ArrayList(usize).empty,
    };
    try server.clients.append(allocator, cli);

    // Pre-populate a pending entry as if `handleBreakPane` wrote it,
    // pointing at broker id=1 with pty_id=5, focus=true.
    try server.pending.put(0, .{
        .cli_msgid = 77,
        .cli_client = cli,
        .broker_id = 1,
        .deadline_ts = std.time.milliTimestamp() + 2000,
        .pty_id = 5,
        .focus = true,
    });

    // Broker fires ok=true reply for request_id=0. The broker is the
    // first attached client (id=1, fd=201) — find it to thread through.
    const broker = blk: {
        for (server.clients.items) |c| {
            if (c.id == 1) break :blk c;
        }
        unreachable;
    };
    var reply_params = [_]msgpack.Value.KeyValue{
        .{ .key = .{ .string = "request_id" }, .value = .{ .unsigned = 0 } },
        .{ .key = .{ .string = "ok" }, .value = .{ .boolean = true } },
    };
    try server.handleBreakPaneReply(broker, .{ .method = "break_pane_reply", .params = .{ .map = &reply_params } });

    // Pending dropped, CLI got its ok=true Response.
    try testing.expectEqual(@as(usize, 0), server.pending.count());
    const cli_msg_opt = try findPendingSendOnFd(allocator, &loop, 300);
    try testing.expect(cli_msg_opt != null);
    const cli_msg = cli_msg_opt.?;
    defer cli_msg.deinit(allocator);
    try testing.expect(cli_msg == .response);

    // Sibling clients (id=2 fd=202, id=3 fd=203) each got a
    // break_pane_applied Notification.
    for ([_]posix.fd_t{ 202, 203 }) |sibling_fd| {
        const sibling_msg_opt = try findPendingSendOnFd(allocator, &loop, sibling_fd);
        try testing.expect(sibling_msg_opt != null);
        const sibling_msg = sibling_msg_opt.?;
        defer sibling_msg.deinit(allocator);
        try testing.expect(sibling_msg == .notification);
        try testing.expectEqualStrings("break_pane_applied", sibling_msg.notification.method);

        var saw_pty_id = false;
        var saw_focus = false;
        try testing.expect(sibling_msg.notification.params == .map);
        for (sibling_msg.notification.params.map) |kv| {
            if (std.mem.eql(u8, kv.key.string, "pty_id")) {
                try testing.expectEqual(@as(u64, 5), kv.value.unsigned);
                saw_pty_id = true;
            } else if (std.mem.eql(u8, kv.key.string, "focus")) {
                try testing.expectEqual(true, kv.value.boolean);
                saw_focus = true;
            }
        }
        try testing.expect(saw_pty_id);
        try testing.expect(saw_focus);
    }

    // Broker (id=1, fd=201) MUST NOT receive break_pane_applied.
    try testing.expect((try findPendingSendOnFd(allocator, &loop, 201)) == null);
}

test "handleBreakPaneReply - spoofed reply from non-broker client is rejected" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var loop = try io.Loop.init(allocator);
    defer loop.deinit();

    var server: Server = .{
        .allocator = allocator,
        .loop = &loop,
        .listen_fd = 100,
        .socket_path = "/tmp/test.sock",
        .clients = std.ArrayList(*Client).empty,
        .ptys = std.AutoHashMap(usize, *Pty).init(allocator),
        .pending = std.AutoHashMap(usize, PendingBreak).init(allocator),
        .pending_forwards = std.AutoHashMap(u32, PendingForward).init(allocator),
        .signal_pipe_fds = undefined,
    };
    defer {
        for (server.clients.items) |c| {
            if (c.send_buffer) |buf| allocator.free(buf);
            for (c.send_queue.items) |buf| allocator.free(buf);
            c.send_queue.deinit(allocator);
            c.attached_ptys.deinit(allocator);
            c.msg_buffer.deinit(allocator);
            allocator.destroy(c);
        }
        server.clients.deinit(allocator);
        server.ptys.deinit();
        server.pending.deinit();
    }

    // Three attached clients: id=1 (legit broker, fd=201), id=2 (sibling, fd=202),
    // id=3 (impostor, fd=203). The pending entry is broker_id=1, so a reply
    // dispatched from id=2 or id=3 must be rejected.
    const ids = [_]usize{ 1, 2, 3 };
    for (ids) |client_id| {
        const c = try allocator.create(Client);
        c.* = .{
            .fd = @intCast(200 + @as(i32, @intCast(client_id))),
            .id = client_id,
            .server = &server,
            .msg_buffer = std.ArrayList(u8).empty,
            .send_queue = std.ArrayList([]u8).empty,
            .attached_ptys = std.ArrayList(usize).empty,
        };
        try c.attached_ptys.append(allocator, 5);
        try server.clients.append(allocator, c);
    }

    // CLI client (originator, blocked on Response).
    const cli = try allocator.create(Client);
    cli.* = .{
        .fd = 300,
        .id = 99,
        .server = &server,
        .msg_buffer = std.ArrayList(u8).empty,
        .send_queue = std.ArrayList([]u8).empty,
        .attached_ptys = std.ArrayList(usize).empty,
    };
    try server.clients.append(allocator, cli);

    // Pending entry expects the broker at id=1.
    try server.pending.put(0, .{
        .cli_msgid = 77,
        .cli_client = cli,
        .broker_id = 1,
        .deadline_ts = std.time.milliTimestamp() + 2000,
        .pty_id = 5,
        .focus = true,
    });

    // Find the impostor (id=3) — a foreign client that did NOT win the
    // broker election but tries to spoof an ok=true reply.
    const impostor = blk: {
        for (server.clients.items) |c| {
            if (c.id == 3) break :blk c;
        }
        unreachable;
    };

    var reply_params = [_]msgpack.Value.KeyValue{
        .{ .key = .{ .string = "request_id" }, .value = .{ .unsigned = 0 } },
        .{ .key = .{ .string = "ok" }, .value = .{ .boolean = true } },
    };
    try server.handleBreakPaneReply(impostor, .{ .method = "break_pane_reply", .params = .{ .map = &reply_params } });

    // Pending entry survived — the legitimate broker (or sweep) can
    // still resolve it.
    try testing.expectEqual(@as(usize, 1), server.pending.count());
    try testing.expect(server.pending.get(0) != null);

    // No Response queued to the CLI; the CLI is still blocked.
    try testing.expect((try findPendingSendOnFd(allocator, &loop, 300)) == null);

    // No `break_pane_applied` Notification queued to siblings or broker.
    for ([_]posix.fd_t{ 201, 202, 203 }) |client_fd| {
        try testing.expect((try findPendingSendOnFd(allocator, &loop, client_fd)) == null);
    }
}

test "sweepPending - expired entries reply broker_timeout and drop" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var loop = try io.Loop.init(allocator);
    defer loop.deinit();

    var server: Server = .{
        .allocator = allocator,
        .loop = &loop,
        .listen_fd = 100,
        .socket_path = "/tmp/test.sock",
        .clients = std.ArrayList(*Client).empty,
        .ptys = std.AutoHashMap(usize, *Pty).init(allocator),
        .pending = std.AutoHashMap(usize, PendingBreak).init(allocator),
        .pending_forwards = std.AutoHashMap(u32, PendingForward).init(allocator),
        .signal_pipe_fds = undefined,
    };
    defer {
        for (server.clients.items) |c| {
            if (c.send_buffer) |buf| allocator.free(buf);
            for (c.send_queue.items) |buf| allocator.free(buf);
            c.send_queue.deinit(allocator);
            c.attached_ptys.deinit(allocator);
            c.msg_buffer.deinit(allocator);
            allocator.destroy(c);
        }
        server.clients.deinit(allocator);
        server.ptys.deinit();
        server.pending.deinit();
    }

    const cli = try allocator.create(Client);
    cli.* = .{
        .fd = 400,
        .id = 7,
        .server = &server,
        .msg_buffer = std.ArrayList(u8).empty,
        .send_queue = std.ArrayList([]u8).empty,
        .attached_ptys = std.ArrayList(usize).empty,
    };
    try server.clients.append(allocator, cli);

    // One expired entry (deadline already past), one fresh entry that
    // should survive the sweep.
    try server.pending.put(0, .{
        .cli_msgid = 11,
        .cli_client = cli,
        .broker_id = 1,
        .deadline_ts = std.time.milliTimestamp() - 1000,
        .pty_id = 5,
        .focus = false,
    });
    try server.pending.put(1, .{
        .cli_msgid = 12,
        .cli_client = cli,
        .broker_id = 1,
        .deadline_ts = std.time.milliTimestamp() + 60_000,
        .pty_id = 6,
        .focus = false,
    });

    server.sweepPending();

    // Expired entry dropped, fresh entry retained.
    try testing.expectEqual(@as(usize, 1), server.pending.count());
    try testing.expect(server.pending.get(0) == null);
    try testing.expect(server.pending.get(1) != null);

    // CLI received a broker_timeout Response for cli_msgid=11.
    const msg_opt = try findPendingSendOnFd(allocator, &loop, 400);
    try testing.expect(msg_opt != null);
    const msg = msg_opt.?;
    defer msg.deinit(allocator);
    try testing.expect(msg == .response);
    try testing.expectEqual(@as(u32, 11), msg.response.msgid);
    try testing.expect(msg.response.err == null);
    try testing.expect(msg.response.result == .map);

    var saw_ok = false;
    var saw_reason = false;
    for (msg.response.result.map) |kv| {
        if (std.mem.eql(u8, kv.key.string, "ok")) {
            try testing.expectEqual(false, kv.value.boolean);
            saw_ok = true;
        } else if (std.mem.eql(u8, kv.key.string, "reason")) {
            try testing.expectEqualStrings("broker_timeout", kv.value.string);
            saw_reason = true;
        }
    }
    try testing.expect(saw_ok);
    try testing.expect(saw_reason);
}

test "removeClient - broker disconnect replies broker_timeout to CLI" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var loop = try io.Loop.init(allocator);
    defer loop.deinit();

    var server: Server = .{
        .allocator = allocator,
        .loop = &loop,
        .listen_fd = 100,
        .socket_path = "/tmp/test.sock",
        .clients = std.ArrayList(*Client).empty,
        .ptys = std.AutoHashMap(usize, *Pty).init(allocator),
        .pending = std.AutoHashMap(usize, PendingBreak).init(allocator),
        .pending_forwards = std.AutoHashMap(u32, PendingForward).init(allocator),
        .signal_pipe_fds = undefined,
        .exit_on_idle = false,
    };
    defer {
        // Survivors only — `removeClient` already tore down the broker.
        for (server.clients.items) |c| {
            if (c.send_buffer) |buf| allocator.free(buf);
            for (c.send_queue.items) |buf| allocator.free(buf);
            c.send_queue.deinit(allocator);
            c.attached_ptys.deinit(allocator);
            c.msg_buffer.deinit(allocator);
            allocator.destroy(c);
        }
        server.clients.deinit(allocator);
        server.ptys.deinit();
        server.pending.deinit();
    }

    // Broker (id=1) and an unrelated CLI client (id=99).
    const broker = try allocator.create(Client);
    broker.* = .{
        .fd = 201,
        .id = 1,
        .server = &server,
        .msg_buffer = std.ArrayList(u8).empty,
        .send_queue = std.ArrayList([]u8).empty,
        .attached_ptys = std.ArrayList(usize).empty,
    };
    try server.clients.append(allocator, broker);

    const cli = try allocator.create(Client);
    cli.* = .{
        .fd = 300,
        .id = 99,
        .server = &server,
        .msg_buffer = std.ArrayList(u8).empty,
        .send_queue = std.ArrayList([]u8).empty,
        .attached_ptys = std.ArrayList(usize).empty,
    };
    try server.clients.append(allocator, cli);

    // Pending entry: broker_id=1, cli_client=cli — broker is the one
    // about to disappear. Deadline is far in the future to prove the
    // sweep is purely disconnect-driven, not deadline-driven.
    try server.pending.put(0, .{
        .cli_msgid = 55,
        .cli_client = cli,
        .broker_id = 1,
        .deadline_ts = std.time.milliTimestamp() + 60_000,
        .pty_id = 9,
        .focus = false,
    });

    server.removeClient(broker);

    // Pending entry dropped.
    try testing.expectEqual(@as(usize, 0), server.pending.count());

    // CLI received a broker_timeout Response.
    const msg_opt = try findPendingSendOnFd(allocator, &loop, 300);
    try testing.expect(msg_opt != null);
    const msg = msg_opt.?;
    defer msg.deinit(allocator);
    try testing.expect(msg == .response);
    try testing.expectEqual(@as(u32, 55), msg.response.msgid);
    try testing.expect(msg.response.result == .map);

    var saw_reason = false;
    for (msg.response.result.map) |kv| {
        if (std.mem.eql(u8, kv.key.string, "ok")) {
            try testing.expectEqual(false, kv.value.boolean);
        } else if (std.mem.eql(u8, kv.key.string, "reason")) {
            try testing.expectEqualStrings("broker_timeout", kv.value.string);
            saw_reason = true;
        }
    }
    try testing.expect(saw_reason);
}

test "drainPendingForShutdown - replies broker_timeout to all and clears" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var loop = try io.Loop.init(allocator);
    defer loop.deinit();

    var server: Server = .{
        .allocator = allocator,
        .loop = &loop,
        .listen_fd = 100,
        .socket_path = "/tmp/test.sock",
        .clients = std.ArrayList(*Client).empty,
        .ptys = std.AutoHashMap(usize, *Pty).init(allocator),
        .pending = std.AutoHashMap(usize, PendingBreak).init(allocator),
        .pending_forwards = std.AutoHashMap(u32, PendingForward).init(allocator),
        .signal_pipe_fds = undefined,
        .exit_on_idle = false,
    };
    defer {
        for (server.clients.items) |c| {
            if (c.send_buffer) |buf| allocator.free(buf);
            for (c.send_queue.items) |buf| allocator.free(buf);
            c.send_queue.deinit(allocator);
            c.attached_ptys.deinit(allocator);
            c.msg_buffer.deinit(allocator);
            allocator.destroy(c);
        }
        server.clients.deinit(allocator);
        server.ptys.deinit();
        server.pending.deinit();
    }

    // Two distinct CLI clients with two pending broker-RPC entries.
    const cli_a = try allocator.create(Client);
    cli_a.* = .{
        .fd = 401,
        .id = 11,
        .server = &server,
        .msg_buffer = std.ArrayList(u8).empty,
        .send_queue = std.ArrayList([]u8).empty,
        .attached_ptys = std.ArrayList(usize).empty,
    };
    try server.clients.append(allocator, cli_a);

    const cli_b = try allocator.create(Client);
    cli_b.* = .{
        .fd = 402,
        .id = 12,
        .server = &server,
        .msg_buffer = std.ArrayList(u8).empty,
        .send_queue = std.ArrayList([]u8).empty,
        .attached_ptys = std.ArrayList(usize).empty,
    };
    try server.clients.append(allocator, cli_b);

    try server.pending.put(0, .{
        .cli_msgid = 71,
        .cli_client = cli_a,
        .broker_id = 1,
        .deadline_ts = std.time.milliTimestamp() + 60_000,
        .pty_id = 5,
        .focus = false,
    });
    try server.pending.put(1, .{
        .cli_msgid = 72,
        .cli_client = cli_b,
        .broker_id = 1,
        .deadline_ts = std.time.milliTimestamp() + 60_000,
        .pty_id = 6,
        .focus = false,
    });

    server.drainPendingForShutdown();

    // Pending fully cleared; both CLIs got broker_timeout Responses.
    try testing.expectEqual(@as(usize, 0), server.pending.count());

    for ([_]struct { fd: posix.fd_t, msgid: u32 }{
        .{ .fd = 401, .msgid = 71 },
        .{ .fd = 402, .msgid = 72 },
    }) |expect| {
        const msg_opt = try findPendingSendOnFd(allocator, &loop, expect.fd);
        try testing.expect(msg_opt != null);
        const msg = msg_opt.?;
        defer msg.deinit(allocator);
        try testing.expect(msg == .response);
        try testing.expectEqual(expect.msgid, msg.response.msgid);

        var saw_reason = false;
        for (msg.response.result.map) |kv| {
            if (std.mem.eql(u8, kv.key.string, "ok")) {
                try testing.expectEqual(false, kv.value.boolean);
            } else if (std.mem.eql(u8, kv.key.string, "reason")) {
                try testing.expectEqualStrings("broker_timeout", kv.value.string);
                saw_reason = true;
            }
        }
        try testing.expect(saw_reason);
    }

    // Idempotent: a second drain on an empty map is a no-op.
    server.drainPendingForShutdown();
    try testing.expectEqual(@as(usize, 0), server.pending.count());
}

test "removeClient - cli disconnect drops pending without reply" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var loop = try io.Loop.init(allocator);
    defer loop.deinit();

    var server: Server = .{
        .allocator = allocator,
        .loop = &loop,
        .listen_fd = 100,
        .socket_path = "/tmp/test.sock",
        .clients = std.ArrayList(*Client).empty,
        .ptys = std.AutoHashMap(usize, *Pty).init(allocator),
        .pending = std.AutoHashMap(usize, PendingBreak).init(allocator),
        .pending_forwards = std.AutoHashMap(u32, PendingForward).init(allocator),
        .signal_pipe_fds = undefined,
        .exit_on_idle = false,
    };
    defer {
        for (server.clients.items) |c| {
            if (c.send_buffer) |buf| allocator.free(buf);
            for (c.send_queue.items) |buf| allocator.free(buf);
            c.send_queue.deinit(allocator);
            c.attached_ptys.deinit(allocator);
            c.msg_buffer.deinit(allocator);
            allocator.destroy(c);
        }
        server.clients.deinit(allocator);
        server.ptys.deinit();
        server.pending.deinit();
    }

    // CLI (id=99) and a separate broker that survives (id=1).
    const broker = try allocator.create(Client);
    broker.* = .{
        .fd = 201,
        .id = 1,
        .server = &server,
        .msg_buffer = std.ArrayList(u8).empty,
        .send_queue = std.ArrayList([]u8).empty,
        .attached_ptys = std.ArrayList(usize).empty,
    };
    try server.clients.append(allocator, broker);

    const cli = try allocator.create(Client);
    cli.* = .{
        .fd = 300,
        .id = 99,
        .server = &server,
        .msg_buffer = std.ArrayList(u8).empty,
        .send_queue = std.ArrayList([]u8).empty,
        .attached_ptys = std.ArrayList(usize).empty,
    };
    try server.clients.append(allocator, cli);

    try server.pending.put(0, .{
        .cli_msgid = 56,
        .cli_client = cli,
        .broker_id = 1,
        .deadline_ts = std.time.milliTimestamp() + 60_000,
        .pty_id = 9,
        .focus = false,
    });

    // Capture pending-send fds BEFORE removeClient so we can prove no
    // spurious sends were queued by the sweep. cancelByFd will drop
    // any send queued to the CLI's own fd, which we don't want here.
    const before_count = blk: {
        var n: usize = 0;
        var it = loop.pending.iterator();
        while (it.next()) |entry| {
            if (entry.value_ptr.kind == .send) n += 1;
        }
        break :blk n;
    };

    server.removeClient(cli);

    // Pending entry dropped.
    try testing.expectEqual(@as(usize, 0), server.pending.count());

    // No new send queued anywhere (the CLI socket is gone, so no
    // Response is attempted; the broker is unrelated to this entry).
    const after_count = blk: {
        var n: usize = 0;
        var it = loop.pending.iterator();
        while (it.next()) |entry| {
            if (entry.value_ptr.kind == .send) n += 1;
        }
        break :blk n;
    };
    try testing.expectEqual(before_count, after_count);
}

test "handleBreakPane - zero attached clients sends synchronous session_not_attached" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var loop = try io.Loop.init(allocator);
    defer loop.deinit();

    var server: Server = .{
        .allocator = allocator,
        .loop = &loop,
        .listen_fd = 100,
        .socket_path = "/tmp/test.sock",
        .clients = std.ArrayList(*Client).empty,
        .ptys = std.AutoHashMap(usize, *Pty).init(allocator),
        .pending = std.AutoHashMap(usize, PendingBreak).init(allocator),
        .pending_forwards = std.AutoHashMap(u32, PendingForward).init(allocator),
        .signal_pipe_fds = undefined,
    };
    defer {
        for (server.clients.items) |c| {
            if (c.send_buffer) |buf| allocator.free(buf);
            for (c.send_queue.items) |buf| allocator.free(buf);
            c.send_queue.deinit(allocator);
            c.attached_ptys.deinit(allocator);
            c.msg_buffer.deinit(allocator);
            allocator.destroy(c);
        }
        server.clients.deinit(allocator);
        server.ptys.deinit();
        server.pending.deinit();
    }

    // CLI client with NO attached PTYs.
    const cli = try allocator.create(Client);
    cli.* = .{
        .fd = 200,
        .id = 0,
        .server = &server,
        .msg_buffer = std.ArrayList(u8).empty,
        .send_queue = std.ArrayList([]u8).empty,
        .attached_ptys = std.ArrayList(usize).empty,
    };
    try server.clients.append(allocator, cli);

    var params = [_]msgpack.Value.KeyValue{
        .{ .key = .{ .string = "pty_id" }, .value = .{ .unsigned = 1 } },
        .{ .key = .{ .string = "focus" }, .value = .{ .boolean = true } },
    };
    try server.handleBreakPane(cli, 42, .{ .map = &params });

    // Synchronous Response queued; pending stays empty.
    try testing.expectEqual(@as(u32, 0), @as(u32, @intCast(server.pending.count())));

    const msg_opt = try findPendingSendOnFd(allocator, &loop, 200);
    try testing.expect(msg_opt != null);
    const msg = msg_opt.?;
    defer msg.deinit(allocator);

    try testing.expect(msg == .response);
    try testing.expectEqual(@as(u32, 42), msg.response.msgid);
    try testing.expect(msg.response.err == null);
    try testing.expect(msg.response.result == .map);

    var got_ok = false;
    var got_reason = false;
    for (msg.response.result.map) |kv| {
        if (std.mem.eql(u8, kv.key.string, "ok")) {
            try testing.expect(kv.value.boolean == false);
            got_ok = true;
        } else if (std.mem.eql(u8, kv.key.string, "reason")) {
            try testing.expectEqualStrings("session_not_attached", kv.value.string);
            got_reason = true;
        }
    }
    try testing.expect(got_ok);
    try testing.expect(got_reason);
}

test "handleBreakPane - broker-pick is lowest Client.id among attached" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var loop = try io.Loop.init(allocator);
    defer loop.deinit();

    var server: Server = .{
        .allocator = allocator,
        .loop = &loop,
        .listen_fd = 100,
        .socket_path = "/tmp/test.sock",
        .clients = std.ArrayList(*Client).empty,
        .ptys = std.AutoHashMap(usize, *Pty).init(allocator),
        .pending = std.AutoHashMap(usize, PendingBreak).init(allocator),
        .pending_forwards = std.AutoHashMap(u32, PendingForward).init(allocator),
        .signal_pipe_fds = undefined,
    };
    defer {
        for (server.clients.items) |c| {
            if (c.send_buffer) |buf| allocator.free(buf);
            for (c.send_queue.items) |buf| allocator.free(buf);
            c.send_queue.deinit(allocator);
            c.attached_ptys.deinit(allocator);
            c.msg_buffer.deinit(allocator);
            allocator.destroy(c);
        }
        server.clients.deinit(allocator);
        server.ptys.deinit();
        server.pending.deinit();
    }

    // Three attached clients with ids 1, 2, 3 (registered out of insert
    // order to verify the comparator looks at id, not insert order).
    const ids = [_]usize{ 3, 1, 2 };
    for (ids) |client_id| {
        const c = try allocator.create(Client);
        c.* = .{
            .fd = @intCast(200 + @as(i32, @intCast(client_id))),
            .id = client_id,
            .server = &server,
            .msg_buffer = std.ArrayList(u8).empty,
            .send_queue = std.ArrayList([]u8).empty,
            .attached_ptys = std.ArrayList(usize).empty,
        };
        try c.attached_ptys.append(allocator, 7);
        try server.clients.append(allocator, c);
    }

    // Add a CLI client with no attachment so it's never the broker.
    const cli = try allocator.create(Client);
    cli.* = .{
        .fd = 999,
        .id = 99,
        .server = &server,
        .msg_buffer = std.ArrayList(u8).empty,
        .send_queue = std.ArrayList([]u8).empty,
        .attached_ptys = std.ArrayList(usize).empty,
    };
    try server.clients.append(allocator, cli);

    var params = [_]msgpack.Value.KeyValue{
        .{ .key = .{ .string = "pty_id" }, .value = .{ .unsigned = 7 } },
        .{ .key = .{ .string = "focus" }, .value = .{ .boolean = false } },
    };

    try server.handleBreakPane(cli, 1, .{ .map = &params });

    try testing.expectEqual(@as(usize, 1), server.pending.count());
    try testing.expectEqual(@as(usize, 1), server.next_request_id);

    const entry_v0 = server.pending.get(0) orelse {
        try testing.expect(false);
        return;
    };
    try testing.expectEqual(@as(usize, 1), entry_v0.broker_id);
    try testing.expectEqual(@as(u32, 7), entry_v0.pty_id);
    try testing.expectEqual(false, entry_v0.focus);
    try testing.expectEqual(@as(u32, 1), entry_v0.cli_msgid);
    try testing.expect(entry_v0.cli_client == cli);

    // The broker (id=1, fd=201) should have received exactly one
    // break_pane_request notification — no other client should see one.
    const broker1_msg_opt = try findPendingSendOnFd(allocator, &loop, 201);
    try testing.expect(broker1_msg_opt != null);
    const broker1_msg = broker1_msg_opt.?;
    defer broker1_msg.deinit(allocator);
    try testing.expect(broker1_msg == .notification);
    try testing.expectEqualStrings("break_pane_request", broker1_msg.notification.method);
    try testing.expect(broker1_msg.notification.params == .map);
    var saw_pty_id = false;
    var saw_focus = false;
    var saw_request_id = false;
    for (broker1_msg.notification.params.map) |kv| {
        if (std.mem.eql(u8, kv.key.string, "pty_id")) {
            try testing.expectEqual(@as(u64, 7), kv.value.unsigned);
            saw_pty_id = true;
        } else if (std.mem.eql(u8, kv.key.string, "focus")) {
            try testing.expectEqual(false, kv.value.boolean);
            saw_focus = true;
        } else if (std.mem.eql(u8, kv.key.string, "request_id")) {
            try testing.expectEqual(@as(u64, 0), kv.value.unsigned);
            saw_request_id = true;
        }
    }
    try testing.expect(saw_pty_id);
    try testing.expect(saw_focus);
    try testing.expect(saw_request_id);
    try testing.expect((try findPendingSendOnFd(allocator, &loop, 202)) == null);
    try testing.expect((try findPendingSendOnFd(allocator, &loop, 203)) == null);
    try testing.expect((try findPendingSendOnFd(allocator, &loop, 999)) == null);

    // Detach client 1 and re-fire — broker should become id 2.
    // (Mutating attached_ptys directly bypasses the detach RPC to keep
    // the test focused on broker selection.)
    for (server.clients.items) |c| {
        if (c.id == 1) {
            c.attached_ptys.clearRetainingCapacity();
            break;
        }
    }

    try server.handleBreakPane(cli, 2, .{ .map = &params });

    try testing.expectEqual(@as(usize, 2), server.pending.count());
    try testing.expectEqual(@as(usize, 2), server.next_request_id);

    const entry_v1 = server.pending.get(1) orelse {
        try testing.expect(false);
        return;
    };
    try testing.expectEqual(@as(usize, 2), entry_v1.broker_id);

    // Broker now id=2 (fd=202) — verify a notification went there.
    const broker2_msg_opt = try findPendingSendOnFd(allocator, &loop, 202);
    try testing.expect(broker2_msg_opt != null);
    const broker2_msg = broker2_msg_opt.?;
    defer broker2_msg.deinit(allocator);
    try testing.expect(broker2_msg == .notification);
    try testing.expectEqualStrings("break_pane_request", broker2_msg.notification.method);
}

test "server - pty exit notification" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var loop = try io.Loop.init(allocator);
    defer loop.deinit();

    var server: Server = .{
        .allocator = allocator,
        .loop = &loop,
        .listen_fd = 100,
        .socket_path = "/tmp/test.sock",
        .clients = std.ArrayList(*Client).empty,
        .ptys = std.AutoHashMap(usize, *Pty).init(allocator),
        .pending = std.AutoHashMap(usize, PendingBreak).init(allocator),
        .signal_pipe_fds = undefined,
        .plugs = std.StringHashMap(*Client).init(allocator),
        .pending_forwards = std.AutoHashMap(u32, PendingForward).init(allocator),
    };
    defer {
        // cleanup
        for (server.clients.items) |client| {
            if (client.send_buffer) |buf| allocator.free(buf);
            for (client.send_queue.items) |buf| allocator.free(buf);
            client.send_queue.deinit(allocator);
            client.attached_ptys.deinit(allocator);
            allocator.destroy(client);
        }
        server.clients.deinit(allocator);
        // PTY is now cleaned up by onPtyDirty when it exits, so just deinit the map
        server.ptys.deinit();
        server.pending.deinit();
    }

    // Add a client
    const client = try allocator.create(Client);
    client.* = .{
        .fd = 200,
        .server = &server,
        .msg_buffer = std.ArrayList(u8).empty,
        .send_queue = std.ArrayList([]u8).empty,
        .attached_ptys = std.ArrayList(usize).empty,
    };
    try server.clients.append(allocator, client);

    // Create a dummy Pty
    const pipe_fds = try posix.pipe2(.{ .NONBLOCK = true, .CLOEXEC = true });
    const exit_pipe_fds = try posix.pipe2(.{ .NONBLOCK = true, .CLOEXEC = true });
    const pty_inst = try allocator.create(Pty);
    pty_inst.* = .{
        .id = 1,
        .process = .{ .master = -1, .slave = -1, .pid = 0 },
        .clients = std.ArrayList(*Client).empty,
        .running = std.atomic.Value(bool).init(true),
        .terminal = try ghostty_vt.Terminal.init(allocator, .{ .cols = 80, .rows = 24 }),
        .allocator = allocator,
        .title = std.ArrayList(u8).empty,
        .title_dirty = false,
        .cwd = std.ArrayList(u8).empty,
        .cwd_dirty = false,
        .pipe_fds = pipe_fds,
        .exit_pipe_fds = exit_pipe_fds,
        .render_state = .empty,
        .server_ptr = &server,
        .exited = std.atomic.Value(bool).init(false),
        .exit_status = std.atomic.Value(u32).init(0),
    };

    try server.ptys.put(1, pty_inst);

    // Register dirty pipe read (like in spawn_pty)
    _ = try loop.read(pty_inst.pipe_fds[0], &pty_inst.dirty_signal_buf, .{
        .ptr = pty_inst,
        .cb = Server.onPtyDirty,
    });

    // Simulate process exit: set status and send "e" signal through pipe
    pty_inst.exit_status.store(123, .seq_cst);
    pty_inst.exited.store(true, .seq_cst);

    // Complete the read with "e" signal
    try loop.completeRead(pty_inst.pipe_fds[0], "e");

    // Run loop to process onPtyDirty -> handleProcessExit
    try loop.run(.once);

    // Check pending sends
    var found_send = false;
    var it = loop.pending.iterator();
    while (it.next()) |entry| {
        if (entry.value_ptr.kind == .send and entry.value_ptr.fd == 200) {
            found_send = true;

            // Verify content
            const msg = try rpc.decodeMessage(allocator, entry.value_ptr.buf);
            defer msg.deinit(allocator);

            try testing.expect(msg == .notification);
            try testing.expectEqualStrings("pty_exited", msg.notification.method);
            try testing.expectEqual(@as(usize, 2), msg.notification.params.array.len);
            try testing.expectEqual(@as(u64, 1), msg.notification.params.array[0].unsigned);
            try testing.expectEqual(@as(u64, 123), msg.notification.params.array[1].unsigned);
        }
    }
    try testing.expect(found_send);
}

test "Server.tabsContainPtyId detects pre-existing pty_id at any tree depth" {
    const testing = std.testing;
    const json =
        \\{
        \\  "tabs": [
        \\    {"id": 1, "root": {"type": "pane", "pty_id": 7}},
        \\    {"id": 4, "root": {
        \\      "type": "split",
        \\      "children": [
        \\        {"type": "pane", "pty_id": 11},
        \\        {"type": "pane", "pty_id": 13}
        \\      ]
        \\    }}
        \\  ]
        \\}
    ;
    var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, json, .{});
    defer parsed.deinit();
    const tabs = parsed.value.object.get("tabs").?;

    try testing.expectEqual(@as(?i64, 1), Server.tabsContainPtyId(tabs, 7));
    try testing.expectEqual(@as(?i64, 4), Server.tabsContainPtyId(tabs, 11));
    try testing.expectEqual(@as(?i64, 4), Server.tabsContainPtyId(tabs, 13));
    try testing.expectEqual(@as(?i64, null), Server.tabsContainPtyId(tabs, 99));
}

// ========================================================================
// Detached-path placement policy tests (fn-32-break-pane-right-of-focus.1)
// ========================================================================
// appendTabToSessionFile now inserts right of the focused tab (the JSON
// active_tab field) instead of appending to the end. The
// computeSessionFileInsertIndex helper encodes the normalize-and-insert
// rule: max(1, min(len, active_tab or 1)) with explicit empty-tabs → 0
// branch, and missing / null / wrong-type active_tab reads all normalize
// to 1. Unit-testing the helper directly is simpler and faster than
// spinning up a Server + filesystem — the file-write portion of
// appendTabToSessionFile is straightforward std.fs and not placement-
// policy-relevant.

test "placePtyInSessionFile active_tab=2 of 3 places new tab at insert index 2 (0-based)" {
    const testing = std.testing;
    const active_tab: std.json.Value = .{ .integer = 2 };
    const insert_idx = Server.computeSessionFileInsertIndex(active_tab, 3);
    // 1-based anchor 2 → 0-based insert index 2 (inserts BEFORE the 3rd
    // existing item), which after insertion places the new tab at 1-based
    // position 3 — right of the focused tab.
    try testing.expectEqual(@as(usize, 2), insert_idx);
}

test "placePtyInSessionFile missing active_tab field normalizes to 1, insert index 1 (0-based)" {
    const testing = std.testing;
    const insert_idx = Server.computeSessionFileInsertIndex(null, 3);
    // Missing key → active_tab = 1; new tab at 1-based position 2
    // (0-based insert index 1).
    try testing.expectEqual(@as(usize, 1), insert_idx);
}

test "placePtyInSessionFile active_tab=null normalizes to 1, insert index 1 (0-based)" {
    const testing = std.testing;
    const active_tab: std.json.Value = .null;
    const insert_idx = Server.computeSessionFileInsertIndex(active_tab, 3);
    try testing.expectEqual(@as(usize, 1), insert_idx);
}

test "placePtyInSessionFile empty tabs array places new tab at index 0 (only tab)" {
    const testing = std.testing;
    const active_tab: std.json.Value = .{ .integer = 2 };
    const insert_idx = Server.computeSessionFileInsertIndex(active_tab, 0);
    // Empty tabs array is a degenerate case — the anchor + 1 rule would
    // overflow (std.json.Array.insert(1, ..) on an empty array panics
    // with index out of bounds). The explicit empty branch returns 0 so
    // the new tab becomes the only tab in the array.
    try testing.expectEqual(@as(usize, 0), insert_idx);
}

test "placePtyInSessionFile active_tab=99 (overflow) clamps to len, insert at end" {
    const testing = std.testing;
    const active_tab: std.json.Value = .{ .integer = 99 };
    const insert_idx = Server.computeSessionFileInsertIndex(active_tab, 3);
    // Clamped to len (3); 1-based 3 → 0-based insert index 3, which lands
    // at the end (equivalent to old append-for-overflow behavior).
    try testing.expectEqual(@as(usize, 3), insert_idx);
}

test "placePtyInSessionFile wrong-type active_tab (string) normalizes to 1" {
    const testing = std.testing;
    const active_tab: std.json.Value = .{ .string = "2" };
    const insert_idx = Server.computeSessionFileInsertIndex(active_tab, 3);
    // Non-integer reads (string, bool, array, object, float) all route
    // through the null-arm of the switch and normalize to 1.
    try testing.expectEqual(@as(usize, 1), insert_idx);
}

test "placePtyInSessionFile active_tab=0 (zero) floors to 1, insert index 1 (0-based)" {
    const testing = std.testing;
    const active_tab: std.json.Value = .{ .integer = 0 };
    const insert_idx = Server.computeSessionFileInsertIndex(active_tab, 3);
    // Zero / negative active_tab values route to 1 via the floored guard.
    try testing.expectEqual(@as(usize, 1), insert_idx);
}

// ========================================================================
// splitTargetPaneInTabs tests (fn-302-spawn-pty-split-for-start-arthack-dash.1)
// ========================================================================
// The pure-tree-mutation core of the new split path. We test against a
// parsed JSON value tree rather than spinning up a Server + filesystem,
// matching the computeSessionFileInsertIndex template.

test "splitTargetPaneInTabs promotes single-pane root into a stacked split" {
    const testing = std.testing;
    const json =
        \\{
        \\  "tabs": [
        \\    {"id": 1, "title": "dash", "root": {"type": "pane", "id": 1, "pty_id": 7, "cwd": "/tmp"}, "last_focused_id": 1}
        \\  ]
        \\}
    ;
    var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, json, .{});
    defer parsed.deinit();

    const tabs_val = parsed.value.object.getPtr("tabs").?;
    const spec: Server.SplitSpec = .{
        .target_pty_id = 7,
        .direction = .col,
        .ratio = 0.5,
    };

    const file_pty_id = try Server.splitTargetPaneInTabs(
        parsed.arena.allocator(),
        tabs_val,
        spec,
        99, // new pane id
        88, // split node id
        "/home/user",
        42, // new pty_id
    );
    try testing.expectEqual(@as(i64, 42), file_pty_id);

    // After mutation: tab 1's root is a split with two pane children, the
    // first being the original pane (id=1, pty_id=7) and the second the
    // new pane (id=99, pty_id=42). The split itself has split_id=88,
    // direction="col". No ratio key on the split node — for the 50/50 default
    // both children carry nil ratio so layoutColumnImpl Pass 3 splits equally.
    const tab_obj = tabs_val.array.items[0].object;
    const root_obj = tab_obj.get("root").?.object;
    try testing.expectEqualStrings("split", root_obj.get("type").?.string);
    try testing.expectEqual(@as(i64, 88), root_obj.get("split_id").?.integer);
    try testing.expectEqualStrings("col", root_obj.get("direction").?.string);
    try testing.expect(root_obj.get("ratio") == null);

    const children = root_obj.get("children").?.array.items;
    try testing.expectEqual(@as(usize, 2), children.len);

    const original = children[0].object;
    try testing.expectEqualStrings("pane", original.get("type").?.string);
    try testing.expectEqual(@as(i64, 1), original.get("id").?.integer);
    try testing.expectEqual(@as(i64, 7), original.get("pty_id").?.integer);

    const new_pane = children[1].object;
    try testing.expectEqualStrings("pane", new_pane.get("type").?.string);
    try testing.expectEqual(@as(i64, 99), new_pane.get("id").?.integer);
    try testing.expectEqual(@as(i64, 42), new_pane.get("pty_id").?.integer);
    try testing.expectEqualStrings("/home/user", new_pane.get("cwd").?.string);

    try testing.expectEqual(@as(i64, 99), tab_obj.get("last_focused_id").?.integer);
}

test "splitTargetPaneInTabs returns SplitTargetNotFound when pty_id absent" {
    const testing = std.testing;
    const json =
        \\{
        \\  "tabs": [
        \\    {"id": 1, "root": {"type": "pane", "id": 1, "pty_id": 7, "cwd": "/tmp"}, "last_focused_id": 1}
        \\  ]
        \\}
    ;
    var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, json, .{});
    defer parsed.deinit();

    const tabs_val = parsed.value.object.getPtr("tabs").?;
    const spec: Server.SplitSpec = .{
        .target_pty_id = 999, // not present
        .direction = .col,
        .ratio = 0.5,
    };

    try testing.expectError(error.SplitTargetNotFound, Server.splitTargetPaneInTabs(
        parsed.arena.allocator(),
        tabs_val,
        spec,
        99,
        88,
        "/home/user",
        42,
    ));
}

test "splitTargetPaneInTabs rejects target inside an existing split (v1 scope)" {
    const testing = std.testing;
    // Tab 2's root is already a split containing pty_id=11. v1 only handles
    // single-pane-root tabs; promotion-into-existing-split is a future task.
    const json =
        \\{
        \\  "tabs": [
        \\    {"id": 1, "root": {"type": "pane", "id": 1, "pty_id": 7, "cwd": "/tmp"}, "last_focused_id": 1},
        \\    {"id": 2, "root": {
        \\      "type": "split",
        \\      "split_id": 5,
        \\      "direction": "col",
        \\      "ratio": 0.5,
        \\      "children": [
        \\        {"type": "pane", "id": 2, "pty_id": 11, "cwd": "/a"},
        \\        {"type": "pane", "id": 3, "pty_id": 13, "cwd": "/b"}
        \\      ]
        \\    }, "last_focused_id": 2}
        \\  ]
        \\}
    ;
    var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, json, .{});
    defer parsed.deinit();

    const tabs_val = parsed.value.object.getPtr("tabs").?;
    const spec: Server.SplitSpec = .{
        .target_pty_id = 11,
        .direction = .col,
        .ratio = 0.5,
    };

    try testing.expectError(error.SplitTargetIsSplitChild, Server.splitTargetPaneInTabs(
        parsed.arena.allocator(),
        tabs_val,
        spec,
        99,
        88,
        "/home/user",
        42,
    ));
}

test "splitTargetPaneInTabs remaps file_pty_id past existing pty_ids on collision" {
    const testing = std.testing;
    // The new pty_id (7) collides with tab 2's existing pane pty_id (7).
    // The remap should bump file_pty_id to one past the highest pane
    // pty_id seen anywhere in the file (mirrors appendTabToSessionFile).
    const json =
        \\{
        \\  "tabs": [
        \\    {"id": 1, "root": {"type": "pane", "id": 1, "pty_id": 3, "cwd": "/tmp"}, "last_focused_id": 1},
        \\    {"id": 2, "root": {"type": "pane", "id": 2, "pty_id": 7, "cwd": "/a"}, "last_focused_id": 2}
        \\  ]
        \\}
    ;
    var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, json, .{});
    defer parsed.deinit();

    const tabs_val = parsed.value.object.getPtr("tabs").?;
    const spec: Server.SplitSpec = .{
        .target_pty_id = 3, // split into tab 1
        .direction = .col,
        .ratio = 0.5,
    };

    const file_pty_id = try Server.splitTargetPaneInTabs(
        parsed.arena.allocator(),
        tabs_val,
        spec,
        99,
        88,
        "/home/user",
        7, // collides with tab 2's pty_id=7
    );
    // 7 collided → bumped past max (7) to 8.
    try testing.expectEqual(@as(i64, 8), file_pty_id);
}

test "splitTargetPaneInTabs honors direction=row and a non-default ratio" {
    const testing = std.testing;
    const json =
        \\{
        \\  "tabs": [
        \\    {"id": 1, "root": {"type": "pane", "id": 1, "pty_id": 7, "cwd": "/tmp"}, "last_focused_id": 1}
        \\  ]
        \\}
    ;
    var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, json, .{});
    defer parsed.deinit();

    const tabs_val = parsed.value.object.getPtr("tabs").?;
    const spec: Server.SplitSpec = .{
        .target_pty_id = 7,
        .direction = .row,
        .ratio = 0.7,
    };

    _ = try Server.splitTargetPaneInTabs(
        parsed.arena.allocator(),
        tabs_val,
        spec,
        99,
        88,
        "/home/user",
        42,
    );

    const root_obj = tabs_val.array.items[0].object.get("root").?.object;
    try testing.expectEqualStrings("row", root_obj.get("direction").?.string);
    // ratio lives on children, not on the split node.
    try testing.expect(root_obj.get("ratio") == null);
    const children = root_obj.get("children").?.array.items;
    try testing.expect(std.math.approxEqAbs(f64, children[0].object.get("ratio").?.float, 0.7, 1e-9));
    try testing.expect(std.math.approxEqAbs(f64, children[1].object.get("ratio").?.float, 0.3, 1e-9));
}

test "splitTargetPaneInTabs asymmetric ratio: children carry r and 1-r, split node has no ratio" {
    const testing = std.testing;
    const json =
        \\{
        \\  "tabs": [
        \\    {"id": 1, "root": {"type": "pane", "id": 1, "pty_id": 7, "cwd": "/tmp"}, "last_focused_id": 1}
        \\  ]
        \\}
    ;
    var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, json, .{});
    defer parsed.deinit();

    const tabs_val = parsed.value.object.getPtr("tabs").?;
    const spec: Server.SplitSpec = .{
        .target_pty_id = 7,
        .direction = .col,
        .ratio = 0.7,
    };

    _ = try Server.splitTargetPaneInTabs(
        parsed.arena.allocator(),
        tabs_val,
        spec,
        99,
        88,
        "/home/user",
        42,
    );

    const root_obj2 = tabs_val.array.items[0].object.get("root").?.object;
    // The split node itself must not carry a ratio key.
    try testing.expect(root_obj2.get("ratio") == null);
    const kids = root_obj2.get("children").?.array.items;
    try testing.expectEqual(@as(usize, 2), kids.len);
    // children[0] is the original pane, gets spec.ratio.
    try testing.expect(std.math.approxEqAbs(f64, kids[0].object.get("ratio").?.float, 0.7, 1e-9));
    // children[1] is the new pane, gets 1.0 - spec.ratio.
    try testing.expect(std.math.approxEqAbs(f64, kids[1].object.get("ratio").?.float, 0.3, 1e-9));
}

test "bumpPastPanePtyIds returns input when tabs array contains no panes" {
    const testing = std.testing;
    // Empty tabs array — nothing to scan, current value passes through.
    const json = "{\"tabs\": []}";
    var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, json, .{});
    defer parsed.deinit();
    const tabs_val = parsed.value.object.get("tabs").?;
    try testing.expectEqual(@as(i64, 5), Server.bumpPastPanePtyIds(tabs_val, 5));
}

test "Pty.addClient is idempotent on duplicate attach" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var pty_inst: Pty = .{
        .id = 1,
        .process = .{ .master = -1, .slave = -1, .pid = 0 },
        .clients = std.ArrayList(*Client).empty,
        .running = std.atomic.Value(bool).init(true),
        .terminal = try ghostty_vt.Terminal.init(allocator, .{ .cols = 80, .rows = 24 }),
        .allocator = allocator,
        .title = std.ArrayList(u8).empty,
        .title_dirty = false,
        .cwd = std.ArrayList(u8).empty,
        .cwd_dirty = false,
        .pipe_fds = undefined,
        .exit_pipe_fds = undefined,
        .render_state = .empty,
        .server_ptr = undefined,
    };
    defer {
        pty_inst.terminal.deinit(allocator);
        pty_inst.render_state.deinit(allocator);
        pty_inst.clients.deinit(allocator);
        pty_inst.title.deinit(allocator);
        pty_inst.cwd.deinit(allocator);
    }

    var client: Client = .{
        .fd = 42,
        .server = undefined,
        .msg_buffer = std.ArrayList(u8).empty,
        .send_queue = std.ArrayList([]u8).empty,
        .attached_ptys = std.ArrayList(usize).empty,
    };

    try testing.expect(!pty_inst.isClientAttached(&client));

    const first = try pty_inst.addClient(allocator, &client);
    try testing.expect(first);
    try testing.expectEqual(@as(usize, 1), pty_inst.clients.items.len);
    try testing.expect(pty_inst.isClientAttached(&client));

    const second = try pty_inst.addClient(allocator, &client);
    try testing.expect(!second);
    try testing.expectEqual(@as(usize, 1), pty_inst.clients.items.len);
}

test "parseSpawnPlugParams - valid params" {
    var kv_buf: [4]msgpack.Value.KeyValue = undefined;
    var cmd_buf: [2]msgpack.Value = .{
        .{ .string = "/usr/bin/echo" },
        .{ .string = "hello" },
    };
    kv_buf[0] = .{ .key = .{ .string = "name" }, .value = .{ .string = "echo" } };
    kv_buf[1] = .{ .key = .{ .string = "cmd" }, .value = .{ .array = &cmd_buf } };
    kv_buf[2] = .{ .key = .{ .string = "restart" }, .value = .{ .boolean = true } };
    kv_buf[3] = .{ .key = .{ .string = "restart_delay_ms" }, .value = .{ .unsigned = 2000 } };

    const params: msgpack.Value = .{ .map = &kv_buf };
    const parsed = Server.parseSpawnPlugParams(params).?;

    try std.testing.expectEqualStrings("echo", parsed.name);
    try std.testing.expectEqual(@as(usize, 2), parsed.cmd.len);
    try std.testing.expect(parsed.restart);
    try std.testing.expectEqual(@as(u32, 2000), parsed.restart_delay_ms);
}

test "parseSpawnPlugParams - missing name returns null" {
    var cmd_buf: [1]msgpack.Value = .{.{ .string = "cmd" }};
    var kv_buf: [1]msgpack.Value.KeyValue = .{
        .{ .key = .{ .string = "cmd" }, .value = .{ .array = &cmd_buf } },
    };

    const params: msgpack.Value = .{ .map = &kv_buf };
    try std.testing.expect(Server.parseSpawnPlugParams(params) == null);
}

test "parseSpawnPlugParams - missing cmd returns null" {
    var kv_buf: [1]msgpack.Value.KeyValue = .{
        .{ .key = .{ .string = "name" }, .value = .{ .string = "test" } },
    };

    const params: msgpack.Value = .{ .map = &kv_buf };
    try std.testing.expect(Server.parseSpawnPlugParams(params) == null);
}

test "parseSpawnPlugParams - empty cmd returns null" {
    var cmd_buf: [0]msgpack.Value = .{};
    var kv_buf: [2]msgpack.Value.KeyValue = .{
        .{ .key = .{ .string = "name" }, .value = .{ .string = "test" } },
        .{ .key = .{ .string = "cmd" }, .value = .{ .array = &cmd_buf } },
    };

    const params: msgpack.Value = .{ .map = &kv_buf };
    try std.testing.expect(Server.parseSpawnPlugParams(params) == null);
}

test "parseSpawnPlugParams - defaults" {
    var cmd_buf: [1]msgpack.Value = .{.{ .string = "run" }};
    var kv_buf: [2]msgpack.Value.KeyValue = .{
        .{ .key = .{ .string = "name" }, .value = .{ .string = "plug" } },
        .{ .key = .{ .string = "cmd" }, .value = .{ .array = &cmd_buf } },
    };

    const params: msgpack.Value = .{ .map = &kv_buf };
    const parsed = Server.parseSpawnPlugParams(params).?;

    try std.testing.expect(!parsed.restart);
    try std.testing.expectEqual(@as(u32, 1000), parsed.restart_delay_ms);
}

test "handleSpawnPlug - idempotent with same managed cmd" {
    const testing = std.testing;

    var loop = try io.Loop.init(testing.allocator);
    defer loop.deinit();

    var server: Server = .{
        .allocator = testing.allocator,
        .loop = &loop,
        .listen_fd = 100,
        .socket_path = "/tmp/test.sock",
        .clients = std.ArrayList(*Client).empty,
        .ptys = std.AutoHashMap(usize, *Pty).init(testing.allocator),
        .signal_pipe_fds = undefined,
        .plugs = std.StringHashMap(*Client).init(testing.allocator),
        .pending = std.AutoHashMap(usize, PendingBreak).init(testing.allocator),
        .pending_forwards = std.AutoHashMap(u32, PendingForward).init(testing.allocator),
    };
    defer {
        for (server.managed_plugs.items) |*mp| mp.deinit(testing.allocator);
        server.managed_plugs.deinit(testing.allocator);
        server.plugs.deinit();
        server.pending_forwards.deinit();
        server.ptys.deinit();
        server.clients.deinit(testing.allocator);
    }

    // Pre-populate a managed plug (restart_delay_ms=1000 matches parsed default)
    const name = try testing.allocator.dupe(u8, "echo");
    const cmd_arg = try testing.allocator.dupe(u8, "echo");
    const cmd = try testing.allocator.alloc([]const u8, 1);
    cmd[0] = cmd_arg;
    try server.managed_plugs.append(testing.allocator, .{
        .name = name,
        .cmd = cmd,
        .restart = false,
        .restart_delay_ms = 1000,
        .pid = 12345,
    });

    // Try to spawn with same name and cmd (restart defaults match)
    var cmd_vals: [1]msgpack.Value = .{.{ .string = "echo" }};
    var kv_buf: [2]msgpack.Value.KeyValue = .{
        .{ .key = .{ .string = "name" }, .value = .{ .string = "echo" } },
        .{ .key = .{ .string = "cmd" }, .value = .{ .array = &cmd_vals } },
    };
    const params: msgpack.Value = .{ .map = &kv_buf };

    const result = try server.handleSpawnPlug(params);
    try testing.expectEqualStrings("ok", result.string);
    testing.allocator.free(result.string);
}

test "handleSpawnPlug - config conflict for external plug" {
    const testing = std.testing;

    var loop = try io.Loop.init(testing.allocator);
    defer loop.deinit();

    var server: Server = .{
        .allocator = testing.allocator,
        .loop = &loop,
        .listen_fd = 100,
        .socket_path = "/tmp/test.sock",
        .clients = std.ArrayList(*Client).empty,
        .ptys = std.AutoHashMap(usize, *Pty).init(testing.allocator),
        .signal_pipe_fds = undefined,
        .plugs = std.StringHashMap(*Client).init(testing.allocator),
        .pending = std.AutoHashMap(usize, PendingBreak).init(testing.allocator),
        .pending_forwards = std.AutoHashMap(u32, PendingForward).init(testing.allocator),
    };
    defer {
        for (server.managed_plugs.items) |*mp| mp.deinit(testing.allocator);
        server.managed_plugs.deinit(testing.allocator);
        server.plugs.deinit();
        server.pending_forwards.deinit();
        server.ptys.deinit();
        server.clients.deinit(testing.allocator);
    }

    // Pre-populate a registered plug
    const plug_name = try testing.allocator.dupe(u8, "myplugin");
    defer testing.allocator.free(plug_name);
    try server.plugs.put(plug_name, undefined);

    // Try to spawn with same name
    var cmd_vals: [1]msgpack.Value = .{.{ .string = "run" }};
    var kv_buf: [2]msgpack.Value.KeyValue = .{
        .{ .key = .{ .string = "name" }, .value = .{ .string = "myplugin" } },
        .{ .key = .{ .string = "cmd" }, .value = .{ .array = &cmd_vals } },
    };
    const params: msgpack.Value = .{ .map = &kv_buf };

    try testing.expectError(error.PlugConfigConflict, server.handleSpawnPlug(params));
}

test "handleSpawnPlug - config conflict with different managed cmd" {
    const testing = std.testing;

    var loop = try io.Loop.init(testing.allocator);
    defer loop.deinit();

    var server: Server = .{
        .allocator = testing.allocator,
        .loop = &loop,
        .listen_fd = 100,
        .socket_path = "/tmp/test.sock",
        .clients = std.ArrayList(*Client).empty,
        .ptys = std.AutoHashMap(usize, *Pty).init(testing.allocator),
        .signal_pipe_fds = undefined,
        .plugs = std.StringHashMap(*Client).init(testing.allocator),
        .pending = std.AutoHashMap(usize, PendingBreak).init(testing.allocator),
        .pending_forwards = std.AutoHashMap(u32, PendingForward).init(testing.allocator),
    };
    defer {
        for (server.managed_plugs.items) |*mp| mp.deinit(testing.allocator);
        server.managed_plugs.deinit(testing.allocator);
        server.plugs.deinit();
        server.pending_forwards.deinit();
        server.ptys.deinit();
        server.clients.deinit(testing.allocator);
    }

    // Pre-populate a managed plug with cmd "echo"
    const name = try testing.allocator.dupe(u8, "echo");
    const cmd_arg = try testing.allocator.dupe(u8, "echo");
    const cmd = try testing.allocator.alloc([]const u8, 1);
    cmd[0] = cmd_arg;
    try server.managed_plugs.append(testing.allocator, .{
        .name = name,
        .cmd = cmd,
        .restart = false,
        .restart_delay_ms = 1000,
        .pid = 12345,
    });

    // Try to spawn with same name but different cmd
    var cmd_vals: [1]msgpack.Value = .{.{ .string = "cat" }};
    var kv_buf: [2]msgpack.Value.KeyValue = .{
        .{ .key = .{ .string = "name" }, .value = .{ .string = "echo" } },
        .{ .key = .{ .string = "cmd" }, .value = .{ .array = &cmd_vals } },
    };
    const params: msgpack.Value = .{ .map = &kv_buf };

    try testing.expectError(error.PlugConfigConflict, server.handleSpawnPlug(params));
}

test "handleSpawnPlug - config conflict with different restart policy" {
    const testing = std.testing;

    var loop = try io.Loop.init(testing.allocator);
    defer loop.deinit();

    var server: Server = .{
        .allocator = testing.allocator,
        .loop = &loop,
        .listen_fd = 100,
        .socket_path = "/tmp/test.sock",
        .clients = std.ArrayList(*Client).empty,
        .ptys = std.AutoHashMap(usize, *Pty).init(testing.allocator),
        .signal_pipe_fds = undefined,
        .plugs = std.StringHashMap(*Client).init(testing.allocator),
        .pending = std.AutoHashMap(usize, PendingBreak).init(testing.allocator),
        .pending_forwards = std.AutoHashMap(u32, PendingForward).init(testing.allocator),
    };
    defer {
        for (server.managed_plugs.items) |*mp| mp.deinit(testing.allocator);
        server.managed_plugs.deinit(testing.allocator);
        server.plugs.deinit();
        server.pending_forwards.deinit();
        server.ptys.deinit();
        server.clients.deinit(testing.allocator);
    }

    // Pre-populate with restart=false
    const name = try testing.allocator.dupe(u8, "echo");
    const cmd_arg = try testing.allocator.dupe(u8, "echo");
    const cmd = try testing.allocator.alloc([]const u8, 1);
    cmd[0] = cmd_arg;
    try server.managed_plugs.append(testing.allocator, .{
        .name = name,
        .cmd = cmd,
        .restart = false,
        .restart_delay_ms = 0,
        .pid = 12345,
    });

    // Same name and cmd but restart=true (via restart key in params)
    var cmd_vals: [1]msgpack.Value = .{.{ .string = "echo" }};
    var kv_buf: [3]msgpack.Value.KeyValue = .{
        .{ .key = .{ .string = "name" }, .value = .{ .string = "echo" } },
        .{ .key = .{ .string = "cmd" }, .value = .{ .array = &cmd_vals } },
        .{ .key = .{ .string = "restart" }, .value = .{ .boolean = true } },
    };
    const params: msgpack.Value = .{ .map = &kv_buf };

    try testing.expectError(error.PlugConfigConflict, server.handleSpawnPlug(params));
}

test "handleSpawnPlug - stopped plug is removed for re-spawn" {
    const testing = std.testing;

    var loop = try io.Loop.init(testing.allocator);
    defer loop.deinit();

    var server: Server = .{
        .allocator = testing.allocator,
        .loop = &loop,
        .listen_fd = 100,
        .socket_path = "/tmp/test.sock",
        .clients = std.ArrayList(*Client).empty,
        .ptys = std.AutoHashMap(usize, *Pty).init(testing.allocator),
        .signal_pipe_fds = undefined,
        .plugs = std.StringHashMap(*Client).init(testing.allocator),
        .pending = std.AutoHashMap(usize, PendingBreak).init(testing.allocator),
        .pending_forwards = std.AutoHashMap(u32, PendingForward).init(testing.allocator),
    };
    defer {
        for (server.managed_plugs.items) |*mp| mp.deinit(testing.allocator);
        server.managed_plugs.deinit(testing.allocator);
        server.plugs.deinit();
        server.pending_forwards.deinit();
        server.ptys.deinit();
        server.clients.deinit(testing.allocator);
    }

    // Pre-populate a stopped plug (pid=null, no restart timer)
    const name = try testing.allocator.dupe(u8, "stale");
    const cmd_arg = try testing.allocator.dupe(u8, "/nonexistent/binary");
    const cmd = try testing.allocator.alloc([]const u8, 1);
    cmd[0] = cmd_arg;
    try server.managed_plugs.append(testing.allocator, .{
        .name = name,
        .cmd = cmd,
        .restart = false,
        .restart_delay_ms = 0,
        .pid = null,
    });

    try testing.expectEqual(@as(usize, 1), server.managed_plugs.items.len);

    // spawn_plug with same name+cmd should remove the stale entry
    // then try to spawn (which fails because the binary doesn't exist)
    var cmd_vals: [1]msgpack.Value = .{.{ .string = "/nonexistent/binary" }};
    var kv_buf: [2]msgpack.Value.KeyValue = .{
        .{ .key = .{ .string = "name" }, .value = .{ .string = "stale" } },
        .{ .key = .{ .string = "cmd" }, .value = .{ .array = &cmd_vals } },
    };
    const params: msgpack.Value = .{ .map = &kv_buf };

    // spawnPlugProcess fails because binary doesn't exist
    const result = server.handleSpawnPlug(params);
    try testing.expectError(error.SpawnFailed, result);

    // The stale entry should have been removed before the spawn attempt
    try testing.expectEqual(@as(usize, 0), server.managed_plugs.items.len);
}

test "handleSpawnPlug - config-owned name rejected with PlugConfigOwned" {
    const testing = std.testing;

    var loop = try io.Loop.init(testing.allocator);
    defer loop.deinit();

    var server: Server = .{
        .allocator = testing.allocator,
        .loop = &loop,
        .listen_fd = 100,
        .socket_path = "/tmp/test.sock",
        .clients = std.ArrayList(*Client).empty,
        .ptys = std.AutoHashMap(usize, *Pty).init(testing.allocator),
        .signal_pipe_fds = undefined,
        .plugs = std.StringHashMap(*Client).init(testing.allocator),
        .pending = std.AutoHashMap(usize, PendingBreak).init(testing.allocator),
        .pending_forwards = std.AutoHashMap(u32, PendingForward).init(testing.allocator),
    };
    defer {
        for (server.managed_plugs.items) |*mp| mp.deinit(testing.allocator);
        server.managed_plugs.deinit(testing.allocator);
        server.plugs.deinit();
        server.pending_forwards.deinit();
        server.ptys.deinit();
        server.clients.deinit(testing.allocator);
    }

    // Pre-populate a config-owned managed plug
    const name = try testing.allocator.dupe(u8, "control-plug");
    const cmd_arg = try testing.allocator.dupe(u8, "/usr/local/bin/control-plug");
    const cmd = try testing.allocator.alloc([]const u8, 1);
    cmd[0] = cmd_arg;
    try server.managed_plugs.append(testing.allocator, .{
        .name = name,
        .cmd = cmd,
        .restart = true,
        .restart_delay_ms = 1000,
        .owner = .config,
        .pid = 12345,
    });

    // Attempt to RPC-spawn with same name (any cmd) — must reject with
    // PlugConfigOwned regardless of whether the cmd matches.
    var cmd_vals: [1]msgpack.Value = .{.{ .string = "/usr/local/bin/control-plug" }};
    var kv_buf: [2]msgpack.Value.KeyValue = .{
        .{ .key = .{ .string = "name" }, .value = .{ .string = "control-plug" } },
        .{ .key = .{ .string = "cmd" }, .value = .{ .array = &cmd_vals } },
    };
    const params: msgpack.Value = .{ .map = &kv_buf };

    try testing.expectError(error.PlugConfigOwned, server.handleSpawnPlug(params));
}

test "handleSpawnPlug - rpc-owned name keeps existing dedup behavior" {
    const testing = std.testing;

    var loop = try io.Loop.init(testing.allocator);
    defer loop.deinit();

    var server: Server = .{
        .allocator = testing.allocator,
        .loop = &loop,
        .listen_fd = 100,
        .socket_path = "/tmp/test.sock",
        .clients = std.ArrayList(*Client).empty,
        .ptys = std.AutoHashMap(usize, *Pty).init(testing.allocator),
        .signal_pipe_fds = undefined,
        .plugs = std.StringHashMap(*Client).init(testing.allocator),
        .pending = std.AutoHashMap(usize, PendingBreak).init(testing.allocator),
        .pending_forwards = std.AutoHashMap(u32, PendingForward).init(testing.allocator),
    };
    defer {
        for (server.managed_plugs.items) |*mp| mp.deinit(testing.allocator);
        server.managed_plugs.deinit(testing.allocator);
        server.plugs.deinit();
        server.pending_forwards.deinit();
        server.ptys.deinit();
        server.clients.deinit(testing.allocator);
    }

    // Pre-populate an rpc-owned managed plug (default owner = .rpc)
    const name = try testing.allocator.dupe(u8, "echo");
    const cmd_arg = try testing.allocator.dupe(u8, "echo");
    const cmd = try testing.allocator.alloc([]const u8, 1);
    cmd[0] = cmd_arg;
    try server.managed_plugs.append(testing.allocator, .{
        .name = name,
        .cmd = cmd,
        .restart = false,
        .restart_delay_ms = 1000,
        .pid = 12345,
    });

    // Same name + same cmd + matching defaults → idempotent "ok"
    var cmd_vals: [1]msgpack.Value = .{.{ .string = "echo" }};
    var kv_buf: [2]msgpack.Value.KeyValue = .{
        .{ .key = .{ .string = "name" }, .value = .{ .string = "echo" } },
        .{ .key = .{ .string = "cmd" }, .value = .{ .array = &cmd_vals } },
    };
    const params: msgpack.Value = .{ .map = &kv_buf };

    const result = try server.handleSpawnPlug(params);
    try testing.expectEqualStrings("ok", result.string);
    testing.allocator.free(result.string);
}

test "plugCmdMatchesParsed - matching commands" {
    const cmd: []const []const u8 = &.{ "echo", "hello" };
    var parsed: [2]msgpack.Value = .{ .{ .string = "echo" }, .{ .string = "hello" } };
    try std.testing.expect(plugCmdMatchesParsed(cmd, &parsed));
}

test "plugCmdMatchesParsed - different lengths" {
    const cmd: []const []const u8 = &.{ "echo", "hello" };
    var parsed: [1]msgpack.Value = .{.{ .string = "echo" }};
    try std.testing.expect(!plugCmdMatchesParsed(cmd, &parsed));
}

test "plugCmdMatchesParsed - different values" {
    const cmd: []const []const u8 = &.{"echo"};
    var parsed: [1]msgpack.Value = .{.{ .string = "cat" }};
    try std.testing.expect(!plugCmdMatchesParsed(cmd, &parsed));
}

test "onPlugExit - reaps exited process" {
    const testing = std.testing;

    var loop = try io.Loop.init(testing.allocator);
    defer loop.deinit();

    var server: Server = .{
        .allocator = testing.allocator,
        .loop = &loop,
        .listen_fd = 100,
        .socket_path = "/tmp/test.sock",
        .clients = std.ArrayList(*Client).empty,
        .ptys = std.AutoHashMap(usize, *Pty).init(testing.allocator),
        .signal_pipe_fds = undefined,
        .plugs = std.StringHashMap(*Client).init(testing.allocator),
        .pending = std.AutoHashMap(usize, PendingBreak).init(testing.allocator),
        .pending_forwards = std.AutoHashMap(u32, PendingForward).init(testing.allocator),
    };
    defer {
        for (server.managed_plugs.items) |*mp| mp.deinit(testing.allocator);
        server.managed_plugs.deinit(testing.allocator);
        server.plugs.deinit();
        server.pending_forwards.deinit();
        server.ptys.deinit();
        server.clients.deinit(testing.allocator);
    }

    const name = try testing.allocator.dupe(u8, "exiter");
    const cmd_arg = try testing.allocator.dupe(u8, "true");
    const cmd = try testing.allocator.alloc([]const u8, 1);
    cmd[0] = cmd_arg;
    const pid: posix.pid_t = 99999;

    const waitpid_task = try loop.waitpid(pid, .{
        .ptr = &server,
        .cb = Server.onPlugExit,
    });

    try server.managed_plugs.append(testing.allocator, .{
        .name = name,
        .cmd = cmd,
        .restart = false,
        .restart_delay_ms = 0,
        .pid = pid,
        .waitpid_task = waitpid_task,
    });

    // Simulate process exit
    try loop.completeWaitpid(pid, 0);
    try loop.run(.once);

    // After exit: pid cleared, no restart scheduled (restart=false)
    const mp = &server.managed_plugs.items[0];
    try testing.expect(mp.pid == null);
    try testing.expect(mp.waitpid_task == null);
    try testing.expectEqual(@as(u32, 0), mp.restart_count);
}

test "onPlugExit - no restart when killed_by_server" {
    const testing = std.testing;

    var loop = try io.Loop.init(testing.allocator);
    defer loop.deinit();

    var server: Server = .{
        .allocator = testing.allocator,
        .loop = &loop,
        .listen_fd = 100,
        .socket_path = "/tmp/test.sock",
        .clients = std.ArrayList(*Client).empty,
        .ptys = std.AutoHashMap(usize, *Pty).init(testing.allocator),
        .signal_pipe_fds = undefined,
        .plugs = std.StringHashMap(*Client).init(testing.allocator),
        .pending = std.AutoHashMap(usize, PendingBreak).init(testing.allocator),
        .pending_forwards = std.AutoHashMap(u32, PendingForward).init(testing.allocator),
    };
    defer {
        for (server.managed_plugs.items) |*mp| mp.deinit(testing.allocator);
        server.managed_plugs.deinit(testing.allocator);
        server.plugs.deinit();
        server.pending_forwards.deinit();
        server.ptys.deinit();
        server.clients.deinit(testing.allocator);
    }

    const name = try testing.allocator.dupe(u8, "killed");
    const cmd_arg = try testing.allocator.dupe(u8, "true");
    const cmd = try testing.allocator.alloc([]const u8, 1);
    cmd[0] = cmd_arg;
    const pid: posix.pid_t = 88888;

    const waitpid_task = try loop.waitpid(pid, .{
        .ptr = &server,
        .cb = Server.onPlugExit,
    });

    try server.managed_plugs.append(testing.allocator, .{
        .name = name,
        .cmd = cmd,
        .restart = true,
        .restart_delay_ms = 0,
        .pid = pid,
        .killed_by_server = true,
        .waitpid_task = waitpid_task,
    });

    try loop.completeWaitpid(pid, 0);
    try loop.run(.once);

    // Should NOT have restarted
    const mp = &server.managed_plugs.items[0];
    try testing.expect(mp.pid == null);
    try testing.expectEqual(@as(u32, 0), mp.restart_count);
}

test "onPlugExit - no restart when shutting_down" {
    const testing = std.testing;

    var loop = try io.Loop.init(testing.allocator);
    defer loop.deinit();

    var server: Server = .{
        .allocator = testing.allocator,
        .loop = &loop,
        .listen_fd = 100,
        .socket_path = "/tmp/test.sock",
        .clients = std.ArrayList(*Client).empty,
        .ptys = std.AutoHashMap(usize, *Pty).init(testing.allocator),
        .signal_pipe_fds = undefined,
        .plugs = std.StringHashMap(*Client).init(testing.allocator),
        .pending = std.AutoHashMap(usize, PendingBreak).init(testing.allocator),
        .pending_forwards = std.AutoHashMap(u32, PendingForward).init(testing.allocator),
        .shutting_down = true,
    };
    defer {
        for (server.managed_plugs.items) |*mp| mp.deinit(testing.allocator);
        server.managed_plugs.deinit(testing.allocator);
        server.plugs.deinit();
        server.pending_forwards.deinit();
        server.ptys.deinit();
        server.clients.deinit(testing.allocator);
    }

    const name = try testing.allocator.dupe(u8, "shutdown");
    const cmd_arg = try testing.allocator.dupe(u8, "true");
    const cmd = try testing.allocator.alloc([]const u8, 1);
    cmd[0] = cmd_arg;
    const pid: posix.pid_t = 77777;

    const waitpid_task = try loop.waitpid(pid, .{
        .ptr = &server,
        .cb = Server.onPlugExit,
    });

    try server.managed_plugs.append(testing.allocator, .{
        .name = name,
        .cmd = cmd,
        .restart = true,
        .restart_delay_ms = 0,
        .pid = pid,
        .waitpid_task = waitpid_task,
    });

    try loop.completeWaitpid(pid, 0);
    try loop.run(.once);

    const mp = &server.managed_plugs.items[0];
    try testing.expect(mp.pid == null);
    try testing.expectEqual(@as(u32, 0), mp.restart_count);
}

test "handleRegisterPlug - valid token succeeds" {
    const testing = std.testing;

    var loop = try io.Loop.init(testing.allocator);
    defer loop.deinit();

    var server: Server = .{
        .allocator = testing.allocator,
        .loop = &loop,
        .listen_fd = 100,
        .socket_path = "/tmp/test.sock",
        .clients = std.ArrayList(*Client).empty,
        .ptys = std.AutoHashMap(usize, *Pty).init(testing.allocator),
        .signal_pipe_fds = undefined,
        .plugs = std.StringHashMap(*Client).init(testing.allocator),
        .pending = std.AutoHashMap(usize, PendingBreak).init(testing.allocator),
        .pending_forwards = std.AutoHashMap(u32, PendingForward).init(testing.allocator),
    };
    defer {
        for (server.managed_plugs.items) |*mp_item| mp_item.deinit(testing.allocator);
        server.managed_plugs.deinit(testing.allocator);
        server.plugs.deinit();
        server.pending_forwards.deinit();
        server.ptys.deinit();
        server.clients.deinit(testing.allocator);
    }

    // Pre-populate a managed plug with a known token
    const token = Server.generatePlugToken();
    const name = try testing.allocator.dupe(u8, "testplug");
    const cmd_arg = try testing.allocator.dupe(u8, "echo");
    const cmd = try testing.allocator.alloc([]const u8, 1);
    cmd[0] = cmd_arg;
    try server.managed_plugs.append(testing.allocator, .{
        .name = name,
        .cmd = cmd,
        .restart = false,
        .restart_delay_ms = 0,
        .token = token,
        .pid = 12345,
    });

    var client: Client = .{
        .fd = 42,
        .server = &server,
        .msg_buffer = std.ArrayList(u8).empty,
        .send_queue = std.ArrayList([]u8).empty,
        .attached_ptys = std.ArrayList(usize).empty,
    };
    defer {
        if (client.plug_name) |pn| testing.allocator.free(pn);
        client.msg_buffer.deinit(testing.allocator);
        client.send_queue.deinit(testing.allocator);
        client.attached_ptys.deinit(testing.allocator);
    }
    try server.clients.append(testing.allocator, &client);

    var kv_buf: [2]msgpack.Value.KeyValue = .{
        .{ .key = .{ .string = "name" }, .value = .{ .string = "testplug" } },
        .{ .key = .{ .string = "token" }, .value = .{ .string = &token } },
    };
    const params: msgpack.Value = .{ .map = &kv_buf };

    const result = try server.handleRegisterPlug(&client, params);
    try testing.expectEqualStrings("ok", result.string);
    testing.allocator.free(result.string);

    try testing.expect(client.plug_name != null);
    try testing.expectEqualStrings("testplug", client.plug_name.?);
    try testing.expect(server.managed_plugs.items[0].registered);
}

test "handleRegisterPlug - missing token returns error" {
    const testing = std.testing;

    var loop = try io.Loop.init(testing.allocator);
    defer loop.deinit();

    var server: Server = .{
        .allocator = testing.allocator,
        .loop = &loop,
        .listen_fd = 100,
        .socket_path = "/tmp/test.sock",
        .clients = std.ArrayList(*Client).empty,
        .ptys = std.AutoHashMap(usize, *Pty).init(testing.allocator),
        .signal_pipe_fds = undefined,
        .plugs = std.StringHashMap(*Client).init(testing.allocator),
        .pending = std.AutoHashMap(usize, PendingBreak).init(testing.allocator),
        .pending_forwards = std.AutoHashMap(u32, PendingForward).init(testing.allocator),
    };
    defer {
        server.plugs.deinit();
        server.pending_forwards.deinit();
        server.ptys.deinit();
        server.clients.deinit(testing.allocator);
    }

    var client: Client = .{
        .fd = 42,
        .server = &server,
        .msg_buffer = std.ArrayList(u8).empty,
        .send_queue = std.ArrayList([]u8).empty,
        .attached_ptys = std.ArrayList(usize).empty,
    };
    defer {
        client.msg_buffer.deinit(testing.allocator);
        client.send_queue.deinit(testing.allocator);
        client.attached_ptys.deinit(testing.allocator);
    }

    // No token field in params
    var kv_buf: [1]msgpack.Value.KeyValue = .{
        .{ .key = .{ .string = "name" }, .value = .{ .string = "testplug" } },
    };
    const params: msgpack.Value = .{ .map = &kv_buf };

    try testing.expectError(error.MissingPlugToken, server.handleRegisterPlug(&client, params));
}

test "handleRegisterPlug - wrong token returns PermissionDenied" {
    const testing = std.testing;

    var loop = try io.Loop.init(testing.allocator);
    defer loop.deinit();

    var server: Server = .{
        .allocator = testing.allocator,
        .loop = &loop,
        .listen_fd = 100,
        .socket_path = "/tmp/test.sock",
        .clients = std.ArrayList(*Client).empty,
        .ptys = std.AutoHashMap(usize, *Pty).init(testing.allocator),
        .signal_pipe_fds = undefined,
        .plugs = std.StringHashMap(*Client).init(testing.allocator),
        .pending = std.AutoHashMap(usize, PendingBreak).init(testing.allocator),
        .pending_forwards = std.AutoHashMap(u32, PendingForward).init(testing.allocator),
    };
    defer {
        for (server.managed_plugs.items) |*mp_item| mp_item.deinit(testing.allocator);
        server.managed_plugs.deinit(testing.allocator);
        server.plugs.deinit();
        server.pending_forwards.deinit();
        server.ptys.deinit();
        server.clients.deinit(testing.allocator);
    }

    const token = Server.generatePlugToken();
    const name = try testing.allocator.dupe(u8, "testplug");
    const cmd_arg = try testing.allocator.dupe(u8, "echo");
    const cmd = try testing.allocator.alloc([]const u8, 1);
    cmd[0] = cmd_arg;
    try server.managed_plugs.append(testing.allocator, .{
        .name = name,
        .cmd = cmd,
        .restart = false,
        .restart_delay_ms = 0,
        .token = token,
        .pid = 12345,
    });

    var client: Client = .{
        .fd = 42,
        .server = &server,
        .msg_buffer = std.ArrayList(u8).empty,
        .send_queue = std.ArrayList([]u8).empty,
        .attached_ptys = std.ArrayList(usize).empty,
    };
    defer {
        client.msg_buffer.deinit(testing.allocator);
        client.send_queue.deinit(testing.allocator);
        client.attached_ptys.deinit(testing.allocator);
    }

    // Use a different token
    const bad_token = Server.generatePlugToken();
    var kv_buf: [2]msgpack.Value.KeyValue = .{
        .{ .key = .{ .string = "name" }, .value = .{ .string = "testplug" } },
        .{ .key = .{ .string = "token" }, .value = .{ .string = &bad_token } },
    };
    const params: msgpack.Value = .{ .map = &kv_buf };

    try testing.expectError(error.PermissionDenied, server.handleRegisterPlug(&client, params));
}

test "handleRegisterPlug - unknown plug name returns PermissionDenied" {
    const testing = std.testing;

    var loop = try io.Loop.init(testing.allocator);
    defer loop.deinit();

    var server: Server = .{
        .allocator = testing.allocator,
        .loop = &loop,
        .listen_fd = 100,
        .socket_path = "/tmp/test.sock",
        .clients = std.ArrayList(*Client).empty,
        .ptys = std.AutoHashMap(usize, *Pty).init(testing.allocator),
        .signal_pipe_fds = undefined,
        .plugs = std.StringHashMap(*Client).init(testing.allocator),
        .pending = std.AutoHashMap(usize, PendingBreak).init(testing.allocator),
        .pending_forwards = std.AutoHashMap(u32, PendingForward).init(testing.allocator),
    };
    defer {
        server.plugs.deinit();
        server.pending_forwards.deinit();
        server.ptys.deinit();
        server.clients.deinit(testing.allocator);
    }

    var client: Client = .{
        .fd = 42,
        .server = &server,
        .msg_buffer = std.ArrayList(u8).empty,
        .send_queue = std.ArrayList([]u8).empty,
        .attached_ptys = std.ArrayList(usize).empty,
    };
    defer {
        client.msg_buffer.deinit(testing.allocator);
        client.send_queue.deinit(testing.allocator);
        client.attached_ptys.deinit(testing.allocator);
    }

    const token = Server.generatePlugToken();
    var kv_buf: [2]msgpack.Value.KeyValue = .{
        .{ .key = .{ .string = "name" }, .value = .{ .string = "nonexistent" } },
        .{ .key = .{ .string = "token" }, .value = .{ .string = &token } },
    };
    const params: msgpack.Value = .{ .map = &kv_buf };

    try testing.expectError(error.PermissionDenied, server.handleRegisterPlug(&client, params));
}

test "handleRegisterPlug - already registered returns error" {
    const testing = std.testing;

    var loop = try io.Loop.init(testing.allocator);
    defer loop.deinit();

    var server: Server = .{
        .allocator = testing.allocator,
        .loop = &loop,
        .listen_fd = 100,
        .socket_path = "/tmp/test.sock",
        .clients = std.ArrayList(*Client).empty,
        .ptys = std.AutoHashMap(usize, *Pty).init(testing.allocator),
        .signal_pipe_fds = undefined,
        .plugs = std.StringHashMap(*Client).init(testing.allocator),
        .pending = std.AutoHashMap(usize, PendingBreak).init(testing.allocator),
        .pending_forwards = std.AutoHashMap(u32, PendingForward).init(testing.allocator),
    };
    defer {
        server.plugs.deinit();
        server.pending_forwards.deinit();
        server.ptys.deinit();
        server.clients.deinit(testing.allocator);
    }

    var client: Client = .{
        .fd = 42,
        .server = &server,
        .msg_buffer = std.ArrayList(u8).empty,
        .send_queue = std.ArrayList([]u8).empty,
        .attached_ptys = std.ArrayList(usize).empty,
        .plug_name = "already",
    };
    defer {
        client.msg_buffer.deinit(testing.allocator);
        client.send_queue.deinit(testing.allocator);
        client.attached_ptys.deinit(testing.allocator);
    }

    var kv_buf: [2]msgpack.Value.KeyValue = .{
        .{ .key = .{ .string = "name" }, .value = .{ .string = "testplug" } },
        .{ .key = .{ .string = "token" }, .value = .{ .string = "deadbeef" } },
    };
    const params: msgpack.Value = .{ .map = &kv_buf };

    try testing.expectError(error.AlreadyRegistered, server.handleRegisterPlug(&client, params));
}

test "onPlugExit - defers when registered" {
    const testing = std.testing;

    var loop = try io.Loop.init(testing.allocator);
    defer loop.deinit();

    var server: Server = .{
        .allocator = testing.allocator,
        .loop = &loop,
        .listen_fd = 100,
        .socket_path = "/tmp/test.sock",
        .clients = std.ArrayList(*Client).empty,
        .ptys = std.AutoHashMap(usize, *Pty).init(testing.allocator),
        .signal_pipe_fds = undefined,
        .plugs = std.StringHashMap(*Client).init(testing.allocator),
        .pending = std.AutoHashMap(usize, PendingBreak).init(testing.allocator),
        .pending_forwards = std.AutoHashMap(u32, PendingForward).init(testing.allocator),
    };
    defer {
        for (server.managed_plugs.items) |*mp| mp.deinit(testing.allocator);
        server.managed_plugs.deinit(testing.allocator);
        server.plugs.deinit();
        server.pending_forwards.deinit();
        server.ptys.deinit();
        server.clients.deinit(testing.allocator);
    }

    const name = try testing.allocator.dupe(u8, "wrapper");
    const cmd_arg = try testing.allocator.dupe(u8, "npx");
    const cmd = try testing.allocator.alloc([]const u8, 1);
    cmd[0] = cmd_arg;
    const pid: posix.pid_t = 55555;

    const waitpid_task = try loop.waitpid(pid, .{
        .ptr = &server,
        .cb = Server.onPlugExit,
    });

    // Put plug name in plugs map to simulate a registered client
    try server.plugs.put(name, undefined);

    try server.managed_plugs.append(testing.allocator, .{
        .name = name,
        .cmd = cmd,
        .restart = true,
        .restart_delay_ms = 1000,
        .pid = pid,
        .registered = true,
        .waitpid_task = waitpid_task,
    });

    // Wrapper process exits
    try loop.completeWaitpid(pid, 0);
    try loop.run(.once);

    const mp = &server.managed_plugs.items[0];
    // Deferred: registered stays true, plug stays in map, no restart yet
    try testing.expect(mp.registered);
    try testing.expect(mp.pid == null);
    try testing.expect(server.plugs.contains(name));
    try testing.expectEqual(@as(u32, 0), mp.restart_count);
}

test "onPlugExit - proceeds when not registered" {
    const testing = std.testing;

    var loop = try io.Loop.init(testing.allocator);
    defer loop.deinit();

    var server: Server = .{
        .allocator = testing.allocator,
        .loop = &loop,
        .listen_fd = 100,
        .socket_path = "/tmp/test.sock",
        .clients = std.ArrayList(*Client).empty,
        .ptys = std.AutoHashMap(usize, *Pty).init(testing.allocator),
        .signal_pipe_fds = undefined,
        .plugs = std.StringHashMap(*Client).init(testing.allocator),
        .pending = std.AutoHashMap(usize, PendingBreak).init(testing.allocator),
        .pending_forwards = std.AutoHashMap(u32, PendingForward).init(testing.allocator),
    };
    defer {
        for (server.managed_plugs.items) |*mp| {
            if (mp.restart_ctx) |ctx| {
                testing.allocator.free(ctx.plug_name);
                testing.allocator.destroy(ctx);
            }
            mp.deinit(testing.allocator);
        }
        server.managed_plugs.deinit(testing.allocator);
        server.plugs.deinit();
        server.pending_forwards.deinit();
        server.ptys.deinit();
        server.clients.deinit(testing.allocator);
    }

    const name = try testing.allocator.dupe(u8, "unregistered");
    const cmd_arg = try testing.allocator.dupe(u8, "true");
    const cmd = try testing.allocator.alloc([]const u8, 1);
    cmd[0] = cmd_arg;
    const pid: posix.pid_t = 44444;

    const waitpid_task = try loop.waitpid(pid, .{
        .ptr = &server,
        .cb = Server.onPlugExit,
    });

    try server.managed_plugs.append(testing.allocator, .{
        .name = name,
        .cmd = cmd,
        .restart = true,
        .restart_delay_ms = 1000,
        .pid = pid,
        .registered = false,
        .waitpid_task = waitpid_task,
    });

    try loop.completeWaitpid(pid, 0);
    try loop.run(.once);

    const mp = &server.managed_plugs.items[0];
    // Immediate teardown: not registered, removed from plugs, restart scheduled
    try testing.expect(!mp.registered);
    try testing.expect(mp.pid == null);
    try testing.expect(!server.plugs.contains(name));
    try testing.expectEqual(@as(u32, 1), mp.restart_count);
    try testing.expect(mp.restart_timer_task != null);
}

test "finishClose - deferred restart when pid null" {
    const testing = std.testing;

    var loop = try io.Loop.init(testing.allocator);
    defer loop.deinit();

    var server: Server = .{
        .allocator = testing.allocator,
        .loop = &loop,
        .listen_fd = 100,
        .socket_path = "/tmp/test.sock",
        .clients = std.ArrayList(*Client).empty,
        .ptys = std.AutoHashMap(usize, *Pty).init(testing.allocator),
        .signal_pipe_fds = undefined,
        .plugs = std.StringHashMap(*Client).init(testing.allocator),
        .pending = std.AutoHashMap(usize, PendingBreak).init(testing.allocator),
        .pending_forwards = std.AutoHashMap(u32, PendingForward).init(testing.allocator),
    };
    defer {
        for (server.managed_plugs.items) |*mp| {
            if (mp.restart_ctx) |ctx| {
                testing.allocator.free(ctx.plug_name);
                testing.allocator.destroy(ctx);
            }
            mp.deinit(testing.allocator);
        }
        server.managed_plugs.deinit(testing.allocator);
        server.plugs.deinit();
        server.pending_forwards.deinit();
        server.ptys.deinit();
        // finishClose removes and destroys the client, so no manual cleanup
        server.clients.deinit(testing.allocator);
    }

    // Managed plug in deferred state: pid=null, registered=true
    const mp_name = try testing.allocator.dupe(u8, "deferred");
    const cmd_arg = try testing.allocator.dupe(u8, "npx");
    const cmd = try testing.allocator.alloc([]const u8, 1);
    cmd[0] = cmd_arg;

    try server.managed_plugs.append(testing.allocator, .{
        .name = mp_name,
        .cmd = cmd,
        .restart = true,
        .restart_delay_ms = 1000,
        .pid = null,
        .registered = true,
    });

    // Heap-allocate client like the real code does (finishClose calls destroy)
    const client = try testing.allocator.create(Client);
    const client_name = try testing.allocator.dupe(u8, "deferred");
    client.* = .{
        .fd = 42,
        .server = &server,
        .msg_buffer = std.ArrayList(u8).empty,
        .send_queue = std.ArrayList([]u8).empty,
        .attached_ptys = std.ArrayList(usize).empty,
        .plug_name = client_name,
    };
    try server.plugs.put(client_name, client);
    try server.clients.append(testing.allocator, client);

    // Simulate client disconnect via finishClose
    client.finishClose(&loop);

    const mp = &server.managed_plugs.items[0];
    // After finishClose: registered cleared, plug removed from map, restart scheduled
    try testing.expect(!mp.registered);
    try testing.expect(!server.plugs.contains(mp_name));
    try testing.expectEqual(@as(u32, 1), mp.restart_count);
    try testing.expect(mp.restart_timer_task != null);
}

test "handleSpawnPlug - registered but pidless treated as active" {
    const testing = std.testing;

    var loop = try io.Loop.init(testing.allocator);
    defer loop.deinit();

    var server: Server = .{
        .allocator = testing.allocator,
        .loop = &loop,
        .listen_fd = 100,
        .socket_path = "/tmp/test.sock",
        .clients = std.ArrayList(*Client).empty,
        .ptys = std.AutoHashMap(usize, *Pty).init(testing.allocator),
        .signal_pipe_fds = undefined,
        .plugs = std.StringHashMap(*Client).init(testing.allocator),
        .pending = std.AutoHashMap(usize, PendingBreak).init(testing.allocator),
        .pending_forwards = std.AutoHashMap(u32, PendingForward).init(testing.allocator),
    };
    defer {
        for (server.managed_plugs.items) |*mp| mp.deinit(testing.allocator);
        server.managed_plugs.deinit(testing.allocator);
        server.plugs.deinit();
        server.pending_forwards.deinit();
        server.ptys.deinit();
        server.clients.deinit(testing.allocator);
    }

    // Plug in deferred state: pid=null, registered=true
    const name = try testing.allocator.dupe(u8, "active-deferred");
    const cmd_arg = try testing.allocator.dupe(u8, "npx");
    const cmd = try testing.allocator.alloc([]const u8, 1);
    cmd[0] = cmd_arg;

    try server.managed_plugs.append(testing.allocator, .{
        .name = name,
        .cmd = cmd,
        .restart = true,
        .restart_delay_ms = 1000,
        .pid = null,
        .registered = true,
    });

    // Same config spawn should return "ok" (treated as active + matching)
    var cmd_vals: [1]msgpack.Value = .{.{ .string = "npx" }};
    var kv_buf: [4]msgpack.Value.KeyValue = .{
        .{ .key = .{ .string = "name" }, .value = .{ .string = "active-deferred" } },
        .{ .key = .{ .string = "cmd" }, .value = .{ .array = &cmd_vals } },
        .{ .key = .{ .string = "restart" }, .value = .{ .boolean = true } },
        .{ .key = .{ .string = "restart_delay_ms" }, .value = .{ .unsigned = 1000 } },
    };
    const params: msgpack.Value = .{ .map = &kv_buf };

    const result = server.handleSpawnPlug(params);
    const val = try result;
    defer testing.allocator.free(val.string);
    try testing.expectEqualStrings("ok", val.string);

    // Different config should return PlugConfigConflict
    var cmd_vals2: [1]msgpack.Value = .{.{ .string = "different-binary" }};
    var kv_buf2: [2]msgpack.Value.KeyValue = .{
        .{ .key = .{ .string = "name" }, .value = .{ .string = "active-deferred" } },
        .{ .key = .{ .string = "cmd" }, .value = .{ .array = &cmd_vals2 } },
    };
    const params2: msgpack.Value = .{ .map = &kv_buf2 };

    try testing.expectError(error.PlugConfigConflict, server.handleSpawnPlug(params2));
}

test "handleRegisterPlug - cancels pending restart timer on late registration" {
    const testing = std.testing;

    var loop = try io.Loop.init(testing.allocator);
    defer loop.deinit();

    var server: Server = .{
        .allocator = testing.allocator,
        .loop = &loop,
        .listen_fd = 100,
        .socket_path = "/tmp/test.sock",
        .clients = std.ArrayList(*Client).empty,
        .ptys = std.AutoHashMap(usize, *Pty).init(testing.allocator),
        .signal_pipe_fds = undefined,
        .plugs = std.StringHashMap(*Client).init(testing.allocator),
        .pending = std.AutoHashMap(usize, PendingBreak).init(testing.allocator),
        .pending_forwards = std.AutoHashMap(u32, PendingForward).init(testing.allocator),
    };
    defer {
        for (server.managed_plugs.items) |*mp| {
            if (mp.restart_ctx) |ctx| {
                testing.allocator.free(ctx.plug_name);
                testing.allocator.destroy(ctx);
            }
            mp.deinit(testing.allocator);
        }
        server.managed_plugs.deinit(testing.allocator);
        server.plugs.deinit();
        server.pending_forwards.deinit();
        server.ptys.deinit();
        server.clients.deinit(testing.allocator);
    }

    // Managed plug with a known token, restart enabled, delay > 0
    const token = Server.generatePlugToken();
    const name = try testing.allocator.dupe(u8, "late-reg");
    const cmd_arg = try testing.allocator.dupe(u8, "npx");
    const cmd = try testing.allocator.alloc([]const u8, 1);
    cmd[0] = cmd_arg;
    const pid: posix.pid_t = 33333;

    const waitpid_task = try loop.waitpid(pid, .{
        .ptr = &server,
        .cb = Server.onPlugExit,
    });

    try server.managed_plugs.append(testing.allocator, .{
        .name = name,
        .cmd = cmd,
        .restart = true,
        .restart_delay_ms = 5000,
        .pid = pid,
        .registered = false,
        .token = token,
        .waitpid_task = waitpid_task,
    });

    // Step 1: Wrapper exits before child registers.
    // onPlugExit sees registered=false → schedules restart timer.
    try loop.completeWaitpid(pid, 0);
    try loop.run(.once);

    const mp = &server.managed_plugs.items[0];
    try testing.expect(mp.pid == null);
    try testing.expectEqual(@as(u32, 1), mp.restart_count);
    try testing.expect(mp.restart_timer_task != null);

    // Step 2: Child connects late and registers with the original token.
    var client: Client = .{
        .fd = 50,
        .server = &server,
        .msg_buffer = std.ArrayList(u8).empty,
        .send_queue = std.ArrayList([]u8).empty,
        .attached_ptys = std.ArrayList(usize).empty,
    };
    defer {
        if (client.plug_name) |pn| testing.allocator.free(pn);
        client.msg_buffer.deinit(testing.allocator);
        client.send_queue.deinit(testing.allocator);
        client.attached_ptys.deinit(testing.allocator);
    }
    try server.clients.append(testing.allocator, &client);

    var kv_buf: [2]msgpack.Value.KeyValue = .{
        .{ .key = .{ .string = "name" }, .value = .{ .string = "late-reg" } },
        .{ .key = .{ .string = "token" }, .value = .{ .string = &token } },
    };
    const params: msgpack.Value = .{ .map = &kv_buf };

    const result = try server.handleRegisterPlug(&client, params);
    testing.allocator.free(result.string);

    // After late registration: registered=true, restart timer cancelled
    try testing.expect(mp.registered);
    try testing.expect(mp.restart_timer_task == null);
    try testing.expect(mp.restart_ctx == null);
}

test "next_client_id is monotonic and unique" {
    const testing = std.testing;

    var loop = try io.Loop.init(testing.allocator);
    defer loop.deinit();

    var server: Server = .{
        .allocator = testing.allocator,
        .loop = &loop,
        .listen_fd = 100,
        .socket_path = "/tmp/test.sock",
        .clients = std.ArrayList(*Client).empty,
        .ptys = std.AutoHashMap(usize, *Pty).init(testing.allocator),
        .signal_pipe_fds = undefined,
        .plugs = std.StringHashMap(*Client).init(testing.allocator),
        .pending = std.AutoHashMap(usize, PendingBreak).init(testing.allocator),
        .pending_forwards = std.AutoHashMap(u32, PendingForward).init(testing.allocator),
    };
    defer {
        server.managed_plugs.deinit(testing.allocator);
        server.plugs.deinit();
        server.pending_forwards.deinit();
        server.ptys.deinit();
        server.clients.deinit(testing.allocator);
    }

    // Simulate the onAccept id-assignment pattern.
    const first = server.next_client_id;
    server.next_client_id += 1;
    const second = server.next_client_id;
    server.next_client_id += 1;
    const third = server.next_client_id;
    server.next_client_id += 1;

    try testing.expectEqual(@as(usize, 1), first);
    try testing.expectEqual(@as(usize, 2), second);
    try testing.expectEqual(@as(usize, 3), third);
    try testing.expect(first != second and second != third and first != third);
}

test "handleNotifyPlugClient - delivers to exact client" {
    const testing = std.testing;

    var loop = try io.Loop.init(testing.allocator);
    defer loop.deinit();

    var server: Server = .{
        .allocator = testing.allocator,
        .loop = &loop,
        .listen_fd = 100,
        .socket_path = "/tmp/test.sock",
        .clients = std.ArrayList(*Client).empty,
        .ptys = std.AutoHashMap(usize, *Pty).init(testing.allocator),
        .signal_pipe_fds = undefined,
        .plugs = std.StringHashMap(*Client).init(testing.allocator),
        .pending = std.AutoHashMap(usize, PendingBreak).init(testing.allocator),
        .pending_forwards = std.AutoHashMap(u32, PendingForward).init(testing.allocator),
    };
    defer {
        server.managed_plugs.deinit(testing.allocator);
        server.plugs.deinit();
        server.pending_forwards.deinit();
        server.ptys.deinit();
        server.clients.deinit(testing.allocator);
    }

    // Two non-plug clients; the notify should land only on id=7.
    var other: Client = .{
        .id = 3,
        .fd = 40,
        .server = &server,
        .msg_buffer = std.ArrayList(u8).empty,
        .send_queue = std.ArrayList([]u8).empty,
        .attached_ptys = std.ArrayList(usize).empty,
    };
    defer {
        if (other.send_buffer) |buf| testing.allocator.free(buf);
        for (other.send_queue.items) |buf| testing.allocator.free(buf);
        other.msg_buffer.deinit(testing.allocator);
        other.send_queue.deinit(testing.allocator);
        other.attached_ptys.deinit(testing.allocator);
    }

    var target: Client = .{
        .id = 7,
        .fd = 41,
        .server = &server,
        .msg_buffer = std.ArrayList(u8).empty,
        .send_queue = std.ArrayList([]u8).empty,
        .attached_ptys = std.ArrayList(usize).empty,
    };
    defer {
        if (target.send_buffer) |buf| testing.allocator.free(buf);
        for (target.send_queue.items) |buf| testing.allocator.free(buf);
        target.msg_buffer.deinit(testing.allocator);
        target.send_queue.deinit(testing.allocator);
        target.attached_ptys.deinit(testing.allocator);
    }

    try server.clients.append(testing.allocator, &other);
    try server.clients.append(testing.allocator, &target);

    var kv_buf: [2]msgpack.Value.KeyValue = .{
        .{ .key = .{ .string = "client_id" }, .value = .{ .unsigned = 7 } },
        .{ .key = .{ .string = "method" }, .value = .{ .string = "refocus" } },
    };
    const params: msgpack.Value = .{ .map = &kv_buf };

    const result = try server.handleNotifyPlugClient(params);
    testing.allocator.free(result.string);

    // Target got the message, other did not.
    try testing.expect(target.send_buffer != null);
    try testing.expect(other.send_buffer == null);
    try testing.expectEqual(@as(usize, 0), other.send_queue.items.len);
}

test "handleNotifyPlugClient - unknown client_id returns error" {
    const testing = std.testing;

    var loop = try io.Loop.init(testing.allocator);
    defer loop.deinit();

    var server: Server = .{
        .allocator = testing.allocator,
        .loop = &loop,
        .listen_fd = 100,
        .socket_path = "/tmp/test.sock",
        .clients = std.ArrayList(*Client).empty,
        .ptys = std.AutoHashMap(usize, *Pty).init(testing.allocator),
        .signal_pipe_fds = undefined,
        .plugs = std.StringHashMap(*Client).init(testing.allocator),
        .pending = std.AutoHashMap(usize, PendingBreak).init(testing.allocator),
        .pending_forwards = std.AutoHashMap(u32, PendingForward).init(testing.allocator),
    };
    defer {
        server.managed_plugs.deinit(testing.allocator);
        server.plugs.deinit();
        server.pending_forwards.deinit();
        server.ptys.deinit();
        server.clients.deinit(testing.allocator);
    }

    var kv_buf: [2]msgpack.Value.KeyValue = .{
        .{ .key = .{ .string = "client_id" }, .value = .{ .unsigned = 999 } },
        .{ .key = .{ .string = "method" }, .value = .{ .string = "refocus" } },
    };
    const params: msgpack.Value = .{ .map = &kv_buf };

    try testing.expectError(error.ClientNotFound, server.handleNotifyPlugClient(params));
}

test "forwardPtyClientEvent - delivers to subscribed plug" {
    const testing = std.testing;

    var loop = try io.Loop.init(testing.allocator);
    defer loop.deinit();

    var server: Server = .{
        .allocator = testing.allocator,
        .loop = &loop,
        .listen_fd = 100,
        .socket_path = "/tmp/test.sock",
        .clients = std.ArrayList(*Client).empty,
        .ptys = std.AutoHashMap(usize, *Pty).init(testing.allocator),
        .signal_pipe_fds = undefined,
        .plugs = std.StringHashMap(*Client).init(testing.allocator),
        .pending = std.AutoHashMap(usize, PendingBreak).init(testing.allocator),
        .pending_forwards = std.AutoHashMap(u32, PendingForward).init(testing.allocator),
    };
    defer {
        server.managed_plugs.deinit(testing.allocator);
        server.plugs.deinit();
        server.pending_forwards.deinit();
        server.ptys.deinit();
        server.clients.deinit(testing.allocator);
    }

    // Pre-register a plug that subscribes to pty_attach via the wildcard.
    const plug_name = try testing.allocator.dupe(u8, "megaplug");
    const sub = try testing.allocator.dupe(u8, "*");
    var subs = try testing.allocator.alloc([]const u8, 1);
    subs[0] = sub;

    var plug_client: Client = .{
        .id = 0,
        .fd = 55,
        .server = &server,
        .msg_buffer = std.ArrayList(u8).empty,
        .send_queue = std.ArrayList([]u8).empty,
        .attached_ptys = std.ArrayList(usize).empty,
        .plug_name = plug_name,
        .plug_subscriptions = subs,
    };
    defer {
        if (plug_client.send_buffer) |buf| testing.allocator.free(buf);
        for (plug_client.send_queue.items) |buf| testing.allocator.free(buf);
        if (plug_client.plug_name) |pn| testing.allocator.free(pn);
        if (plug_client.plug_subscriptions) |ss| {
            for (ss) |s| testing.allocator.free(s);
            testing.allocator.free(ss);
        }
        plug_client.msg_buffer.deinit(testing.allocator);
        plug_client.send_queue.deinit(testing.allocator);
        plug_client.attached_ptys.deinit(testing.allocator);
    }

    try server.clients.append(testing.allocator, &plug_client);
    try server.plugs.put(plug_name, &plug_client);

    server.forwardPtyClientEvent("pty_attach", 42, 7);

    // The plug should have received one message.
    try testing.expect(plug_client.send_buffer != null);
}

test "handleRegisterPlug - replays client_connected for existing clients" {
    const testing = std.testing;

    var loop = try io.Loop.init(testing.allocator);
    defer loop.deinit();

    var server: Server = .{
        .allocator = testing.allocator,
        .loop = &loop,
        .listen_fd = 100,
        .socket_path = "/tmp/test.sock",
        .clients = std.ArrayList(*Client).empty,
        .ptys = std.AutoHashMap(usize, *Pty).init(testing.allocator),
        .signal_pipe_fds = undefined,
        .plugs = std.StringHashMap(*Client).init(testing.allocator),
        .pending = std.AutoHashMap(usize, PendingBreak).init(testing.allocator),
        .pending_forwards = std.AutoHashMap(u32, PendingForward).init(testing.allocator),
    };
    defer {
        for (server.managed_plugs.items) |*mp_item| mp_item.deinit(testing.allocator);
        server.managed_plugs.deinit(testing.allocator);
        server.plugs.deinit();
        server.pending_forwards.deinit();
        server.ptys.deinit();
        server.clients.deinit(testing.allocator);
    }

    // Two non-plug clients already on the server, both confirmed non-plug
    // (notified_plugs=true simulates having sent their first non-register RPC).
    var tui_a: Client = .{
        .id = 11,
        .fd = 60,
        .server = &server,
        .msg_buffer = std.ArrayList(u8).empty,
        .send_queue = std.ArrayList([]u8).empty,
        .attached_ptys = std.ArrayList(usize).empty,
        .notified_plugs = true,
    };
    defer {
        if (tui_a.send_buffer) |buf| testing.allocator.free(buf);
        for (tui_a.send_queue.items) |buf| testing.allocator.free(buf);
        tui_a.msg_buffer.deinit(testing.allocator);
        tui_a.send_queue.deinit(testing.allocator);
        tui_a.attached_ptys.deinit(testing.allocator);
    }
    var tui_b: Client = .{
        .id = 12,
        .fd = 61,
        .server = &server,
        .msg_buffer = std.ArrayList(u8).empty,
        .send_queue = std.ArrayList([]u8).empty,
        .attached_ptys = std.ArrayList(usize).empty,
        .notified_plugs = true,
    };
    defer {
        if (tui_b.send_buffer) |buf| testing.allocator.free(buf);
        for (tui_b.send_queue.items) |buf| testing.allocator.free(buf);
        tui_b.msg_buffer.deinit(testing.allocator);
        tui_b.send_queue.deinit(testing.allocator);
        tui_b.attached_ptys.deinit(testing.allocator);
    }
    try server.clients.append(testing.allocator, &tui_a);
    try server.clients.append(testing.allocator, &tui_b);

    // Managed plug pre-seeded so handleRegisterPlug finds its token.
    const token = Server.generatePlugToken();
    const mp_name = try testing.allocator.dupe(u8, "replay-plug");
    const cmd_arg = try testing.allocator.dupe(u8, "echo");
    const cmd_slice = try testing.allocator.alloc([]const u8, 1);
    cmd_slice[0] = cmd_arg;
    try server.managed_plugs.append(testing.allocator, .{
        .name = mp_name,
        .cmd = cmd_slice,
        .restart = false,
        .restart_delay_ms = 0,
        .token = token,
        .pid = 12345,
    });

    // Plug subscribes to client_connected (via wildcard) so the replay fires.
    var plug_client: Client = .{
        .id = 0,
        .fd = 62,
        .server = &server,
        .msg_buffer = std.ArrayList(u8).empty,
        .send_queue = std.ArrayList([]u8).empty,
        .attached_ptys = std.ArrayList(usize).empty,
    };
    defer {
        if (plug_client.send_buffer) |buf| testing.allocator.free(buf);
        for (plug_client.send_queue.items) |buf| testing.allocator.free(buf);
        if (plug_client.plug_name) |pn| testing.allocator.free(pn);
        if (plug_client.plug_subscriptions) |ss| {
            for (ss) |s| testing.allocator.free(s);
            testing.allocator.free(ss);
        }
        plug_client.msg_buffer.deinit(testing.allocator);
        plug_client.send_queue.deinit(testing.allocator);
        plug_client.attached_ptys.deinit(testing.allocator);
    }
    try server.clients.append(testing.allocator, &plug_client);

    var sub_arr: [1]msgpack.Value = .{.{ .string = "*" }};
    var kv_buf: [3]msgpack.Value.KeyValue = .{
        .{ .key = .{ .string = "name" }, .value = .{ .string = "replay-plug" } },
        .{ .key = .{ .string = "token" }, .value = .{ .string = &token } },
        .{ .key = .{ .string = "subscribe" }, .value = .{ .array = &sub_arr } },
    };
    const params: msgpack.Value = .{ .map = &kv_buf };

    const result = try server.handleRegisterPlug(&plug_client, params);
    testing.allocator.free(result.string);

    // Plug should have client_connected for both tui_a and tui_b: first
    // lands in send_buffer, the second queues behind it. No extras.
    try testing.expect(plug_client.send_buffer != null);
    try testing.expectEqual(@as(usize, 1), plug_client.send_queue.items.len);
}
