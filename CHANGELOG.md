# Changelog

## 1.9.0 (2026-06-05)

**Publisher:** RecklessGalaxy.com · **Developer:** Sagor Hossen

### Highlights

- **QA roadmap (items 1–28)**: storage transparency, transfer center, pause/resume/retry controls, file-port auth tokens, encrypted transfers, checksums, concurrent sends, incoming-offer notifications, signed discovery, settings import/export, and partial-download management.

### Bug fixes (audit)

- **File transfer**: resumed transfers with checksums no longer delete the completed file on a false mismatch; folder-direct receives now finalize only after all files arrive (not after the first); encrypted-chunk length prefix is bounded; AES-GCM nonce widened to 64-bit to remove any wrap.
- **Connections**: simultaneous-connect (glare) no longer leaks a socket or tears down the healthy connection; socket teardown is identity-guarded.
- **Discovery**: IPv6 socket and listener are closed on stop; rebind is serialized against concurrent network/resume events; display names are sanitized against the `|` delimiter.
- **Storage**: the Storage screen can no longer hang on an unreadable folder; partial-download listing is read-only and never deletes paused transfers — cleanup is now an explicit action.
- **UI**: Transfer Center progress no longer freezes mid-transfer; Settings "Open folder" works on macOS/Linux; cancelling the folder-as-ZIP prompt no longer leaves a phantom message.
- **Android**: inbound shares are re-queued instead of lost when a chat unmounts mid-delivery; consumer detach is identity-checked.
- **Data**: LAN-identity merges tolerate primary-key collisions; id-less incoming messages are rejected instead of collapsing into one row.

### Notes

- Alpha builds are for testing. Report issues via the contact on the Settings screen.

---

## 1.8.0 (2026-04-30)

**Publisher:** RecklessGalaxy.com · **Developer:** Sagor Hossen

### Changes

- **Startup**: splash screen paints immediately on launch; heavy init (SQLite, sockets, notifications) runs behind it so the app feels instant
- **Boot performance**: `DeviceInfo` and `MessageStore` init now run in parallel — faster cold start
- **File transfer UX**: attempting to send files without a LAN connection now shows "File transfer needs a LAN connection" instead of silently ignoring the action; drop target disabled when no active connection
- **Web compatibility**: `kIsWeb` guards added throughout so the binary compiles and runs on web targets without crashes (LAN and SQLite features remain desktop/mobile only)
- **Taskbar flash (Windows)**: refactored to a conditional export (`_io` / `_stub`) — no runtime `kIsWeb` check on every call
- **Global Discovery removed**: experimental Nostr/WebRTC cross-network pairing feature removed entirely; codebase reverted to stable LAN-only foundation
- **Resource leaks fixed**: UDP datagram subscription now stored and cancelled on rebind/stop; `TransferManager` stream controllers and notification timer properly disposed; `fileMessages` subscription cancelled on app widget dispose
- **Connection reliability**: `connectTo()` now guards against two concurrent dials to the same peer racing and leaving a zombie socket
- **Security**: 1 MB line-length limit on incoming TCP JSON frames — socket destroyed immediately if a peer sends an unbounded frame
- **Android multicast lock**: released correctly if UDP socket bind fails during `start()`

### Notes

- Alpha builds are for testing. Report issues via the contact on the Settings screen.

---

## 1.7.0 (2026-03-31)

### Highlights

- UDP broadcast discovery, TCP chat (JSON), separate TCP file transfer with chunked streaming, pause/resume, delivery states
- End-to-end encryption for chat messages
- Outbound attachment copies persisted under app documents; Android share/SAF deferred until send; folder zip on send
- Android: notifications, battery hint, share-in, native folder picker, clipboard image copy via `FileProvider`
- Windows: system tray, background mode, autostart, taskbar attention
- Composer paste image, snackbars below app bar, theme modes

---

## Earlier

Prior releases not tracked here — see git history.
