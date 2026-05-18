## Description

**Size:** M
**Files:** src/client.zig (primary), src/main.zig (if new test file needs registration)

### Approach

Branch from `arthack-prod` as `fix/concurrent-attach-coalesce`. Read `AGENTS.md` and `~/docs/prise-scratchpad.md` at session start per `/prise-develop` conventions.

**Fix site 1 — deferred-attach drain (`pending_attach_pty_id` scalar):**

1. Delete the dead fields at line 1076-1077 (`pending_attach_ids: ?[]u32`, `pending_attach_count: usize`) and replace the scalar `pending_attach_pty_id: ?u32` with `pending_attach_ids: std.ArrayList(u32)` initialized `.empty` in the struct literal and deinit'd in `App.deinit`.
2. Add constant: `const MAX_PENDING_ATTACH_IDS: usize = 64;`
3. In `attachCb` (line ~1584): replace the scalar assign with a bounds check + `append`. On overflow, `log.warn` and return (drop-newest). On allocator failure, `log.err` and return.
4. In the drain site (line ~3802): replace the `if (app.pending_attach_pty_id) |pty_id|` block with a loop over `pending_attach_ids.items`. For each id: build the `attach_pty` msgpack frame into a local buffer, call `app.sendDirect(frame)`, free the buffer inline. After the loop, call `pending_attach_ids.clearRetainingCapacity()`. Do NOT touch `app.send_buffer` — this path is fully synchronous and decoupled from the async send lifecycle.

**Fix site 2 — `send_attach` ClientLogic arm (line ~3354-3362):**

Replace `app.send_buffer = encode(...); l.send(app.fd, app.send_buffer.?, ...)` with `const frame = encode(...); defer free(frame); try app.sendDirect(frame)`. Same pattern as fix site 1's per-id loop iteration. Same reasoning: multiple `send_attach` actions from one `processServerMessage` batch coalesce on the same `(fd, EVFILT_WRITE)` kevent.

**Why `sendDirect` is safe here:** The drain runs on the `recv_task` completion stack. The existing comments at lines ~1102-1129 and ~3690-3705 warn against calling `l.send` or cancelling `recv_task` from here. `sendDirect` bypasses kqueue entirely — it is the documented escape hatch for this context. The peer is the prise server (a separate process), so there is no same-loop deadlock risk.

**Test:** Add an inline test in `src/client.zig` that:
1. Creates a socketpair (`posix.socketpair`)
2. Appends 3 distinct pty_ids to `pending_attach_ids`
3. Calls the drain logic
4. Reads from the other end and asserts 3 `attach_pty` msgpack frames arrive with the correct ids (FIFO order)

Do NOT use the mock io.Loop for this test — it does not emulate kqueue coalescing. The socketpair test directly exercises `sendDirect` and validates the "all N ids arrive" invariant.

Pre-commit: `zig build fmt && zig build && zig build test`. Commit to `fix/concurrent-attach-coalesce` only. After committing, read `claude/prise/references/build.md` and run `prise-build` to integrate the branch into `arthack-prod`.

### Investigation targets

**Required** (read before coding):
- `src/client.zig:1076-1090` — App struct field declarations; locate `pending_attach_pty_id`, dead fields, `pending_attach_cwd` (cwd is `null` for deferred-attach path — ArrayList of u32 is correct, no cwd needed)
- `src/client.zig:1583-1590` — `attachCb`: the Lua `prise.attach()` callback; rewrite to `append` into list
- `src/client.zig:3800-3825` — drain site: the buggy `if (app.pending_attach_pty_id)` block to replace
- `src/client.zig:3350-3370` — `.send_attach` switch arm: sibling coalescing site to fix
- `src/client.zig:3875-3895` — `sendDirect` implementation: the synchronous write-loop with `WouldBlock` retry; use this, do not invent a new mechanism
- `src/client.zig:1100-1130` — comments documenting the recv_task completion stack safety contract
- `src/io/kqueue.zig:239-269` — `send()` / `EV_ADD | EV_ONESHOT` coalescing: understand the root cause, confirm fix sidesteps it
- `~/src/possibilities--prise/AGENTS.md` — Zig style, TigerStyle safety, build commands, commit message format
- `~/docs/prise-scratchpad.md` — prior session context (read at session start)

**Optional** (reference as needed):
- `src/io/kqueue.zig:633-695` — kqueue integration test template (socketpair pattern) for the regression test
- `src/client.zig:3285-3310` — `onSendComplete`: async-send completion that frees `send_buffer`; understand to confirm the drain fix does NOT involve `send_buffer`
- `src/ui.zig:1295-1315` — `luaAttach` / `queue_attach_pty_callback`: the Lua binding that calls `attachCb`; understand to confirm fire-and-forget semantics
- `src/lua/tiling.lua:4862` — Lua call site: `prise.attach(data.id)` in `pty_spawned` handler; the trigger for the concurrent burst
- `claude/prise/references/build.md` — read before running `prise-build`

### Risks

- `App.deinit` ordering: `pending_attach_ids.deinit()` must be added. Confirm it is called before any other field that owns the same allocator, and that an empty list deinit is a no-op (it is for `std.ArrayList`).
- `attachCb` uses `app_ptr`'s allocator field — confirm the field name (`app_ptr.allocator` or `app_ptr.state.allocator`) before writing the `append` call.
- The `send_attach` arm fix: if `msgpack.encode` returns an allocator-owned buffer, ensure `defer allocator.free(frame)` covers the error path too (use `errdefer` or inline `try` + `defer`).
- `pending_attach_ids.clearRetainingCapacity()` after the drain loop is preferred over `shrinkAndFree` to avoid re-allocation on the next burst.

### Test notes

The regression test needs a real socketpair, not a mock loop. Template: `src/io/kqueue.zig:633-695` shows the `posix.socketpair` + read-loop pattern. Assert frame count (3) and pty_ids in order. Register the test in `src/main.zig` if it lives in a new file; if inline in `src/client.zig`, it is already covered.

## Acceptance

- [ ] `pending_attach_pty_id: ?u32` scalar removed; `pending_attach_ids: std.ArrayList(u32)` replaces it; dead fields `pending_attach_ids: ?[]u32` and `pending_attach_count: usize` deleted
- [ ] `MAX_PENDING_ATTACH_IDS: usize = 64` constant defined; `attachCb` drops with `log.warn` on overflow, `log.err` on OOM
- [ ] Drain loop in `onRecv` sends all pending ids via `sendDirect`; `app.send_buffer` is not touched by this path
- [ ] `.send_attach` arm replaces `l.send` with `sendDirect`
- [ ] Regression test: 3 ids queued → 3 `attach_pty` frames on wire (FIFO)
- [ ] `zig build fmt && zig build && zig build test` pass on `fix/concurrent-attach-coalesce`
- [ ] Branch committed to `fix/concurrent-attach-coalesce`; `prise-build` integrates cleanly into `arthack-prod`
- [ ] Autopilot at 4x concurrency produces 4 tabs (manual smoke test)

## Done summary

## Evidence
