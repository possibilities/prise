## Overview

When autopilot fires N concurrent workers, N `pty_spawned` events arrive in a single `onRecv` TCP batch. The while loop processes all N, drains `pending_attach_pty_id` N times, and calls `l.send(fd, buf, cb)` N times. kqueue's `EV_ADD | EV_ONESHOT` on an existing `(ident, filter)` pair updates the entry in place — only the last `udata` survives — so only one `attach_pty` RPC fires and only one tab appears. The other N-1 PTYs run invisible. Fix: replace the scalar `pending_attach_pty_id: ?u32` with `std.ArrayList(u32)` and flush all pending IDs via `sendDirect` (synchronous write, no kqueue involvement) so all N `attach_pty` RPCs reach the server.

## Quick commands

- `zig build test` — regression test passes (3 queued ids → 3 frames on wire)
- Manual smoke: start prise, enable autopilot at 4x concurrency, verify 4 tabs appear simultaneously

## Acceptance

- [ ] N concurrent `pty_spawned` events in one `onRecv` batch produce N tabs, not 1
- [ ] `pending_attach_pty_id: ?u32` scalar gone; `pending_attach_ids: std.ArrayList(u32)` with cap 64 in place
- [ ] `.send_attach` ClientLogic arm (client.zig:~3354) also fixed (same coalescing pattern)
- [ ] `zig build fmt && zig build && zig build test` pass on `fix/concurrent-attach-coalesce`
- [ ] `prise-build` integrates branch cleanly into `arthack-prod`

## Early proof point

Task that proves the approach: `fn-1-fix-concurrent-attach-pty-dispatch.1`. If it fails: fall back to staggered dispatch on the arthack side — add `time.sleep(0.15)` between consecutive `Popen` calls in `apps/jobctl/jobctl/run_run_server.py` `_verb_dispatch_fire`, which spreads `pty_spawned` events across separate `onRecv` batches.

## References

- `src/client.zig:3877-3886` — `sendDirect`: existing synchronous write-loop used by 20+ call sites; the fix vehicle
- `src/io/kqueue.zig:239-269` — `send()` EV_ADD coalescing: the root cause
- `src/lua/tiling.lua:4862` — `prise.attach(data.id)` in `pty_spawned` Lua handler: the concurrent burst trigger
- `fn-525` (reverse dep) — autoack-closes-prise-pty: reliability under concurrent spawn load improves once this fix ships; coordinate verification order

## Docs gaps

- **`ARCHITECTURE.md`**: The "Client Architecture" section describes the event loop but says nothing about how `attach_pty` RPCs are dispatched from `onRecv`. After this fix the scalar drain is gone; a one-line note on the list-flush + `sendDirect` pattern would keep the doc trustworthy.

## Best practices

- **Treat `(ident, filter)` as the kqueue uniqueness key:** `EV_ADD` on an existing entry updates `udata` in-place — re-registering the same `(fd, EVFILT_WRITE)` within one event-loop tick coalesces all sends into one callback for the last entry. Never call `l.send()` multiple times on the same fd within a single `onRecv` completion. [kqueue(2) man page]
- **Use `sendDirect` for same-tick flushes:** when multiple sends must fire within the same `onRecv` stack frame, `sendDirect` (synchronous `posix.write` loop) sidesteps kqueue entirely and is safe on Unix-socket connections to a separate-process peer. This is the existing documented escape hatch for the recv_task completion stack. [client.zig:~1102 comments, practice-scout]
- **Cap async queues with named constants:** any collection that accumulates work between event-loop ticks should have an explicit `MAX_*` constant with a defined overflow policy — drop + log.warn for non-critical items, `@panic` only when hitting the cap would indicate a real invariant violation that should never happen. [AGENTS.md TigerStyle]
