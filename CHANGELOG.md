# Changelog

## Unreleased - Dev-LocalChatV5-GlobalDiscovery

- Added optional Global Discovery V5: pairing, Nostr rendezvous, WebRTC data channel setup, and Noise-framed global text transport.
- Kept V4 LAN discovery, TCP chat, SQLite message history, notifications, and file transfer as the authoritative systems.
- Global file transfer remains disabled until a `TransferManager` data-channel adapter is implemented.
- Settings now show live relay status (count, connecting / no-relay state) and a progress bar while toggling Global Discovery.
- `NostrClient` keeps a target relay set and reconnects with exponential backoff after WebSocket drops; active subscriptions replay automatically on each fresh relay connection.
- Pairing screen blocks publish/join when no relays are reachable and surfaces a relay-health banner so "shows nothing" failures explain themselves.
- Pairing responder no longer commits a session when its accept event was dropped on the floor (zero relays); it releases the claim so the next initiator offer can retry.
- Global-only peer disconnect events now flow through `ConnectionService.disconnectedPeerEvents`, refreshing Home / Chat lists like a LAN TCP loss.
- Cold start no longer awaits Nostr relay handshakes before `runApp`; the Global Discovery instance is wired synchronously and connect runs in the background.
- Two-phase boot: the splash screen now renders on the very first Flutter frame while identity load, SQLite open, socket binds, file-receiver, notifications, and global discovery setup run behind it. Cold-start UI feel is effectively instant on every platform.
- Bootstrap I/O is parallelized: identity / device info / message store run together, then TCP + UDP + transfer-receiver + notifications init together. Total wall time drops to roughly the slowest single step instead of the sum.
- New web pre-splash in `web/index.html` plus a Dart-level `AppBootError` screen so the web build no longer shows a blank white page; sqflite / dart:io failures surface a readable diagnostic instead of crashing silently.
- Web platform guards in `app_settings.dart` and `device.dart` so SharedPreferences-only paths (theme, identity, paired peers) initialize without dart:io. LAN, file transfer, and SQLite history remain desktop / mobile only and now exit through the bootstrap error path with a clear message.

---

## Alpha 1.7.0 (2026-03-31)

**Publisher:** RecklessGalaxy.com · **Developer:** Sagor Hossen

### Highlights

- **Networking:** UDP broadcast discovery, TCP chat (JSON), separate TCP file transfer with chunked streaming, pause/resume, delivery states.
- **Security:** End-to-end encryption for chat messages ([`lib/chat_crypto.dart`](lib/chat_crypto.dart)).
- **Attachments:** Outbound copies persisted under app documents so sent thumbnails stay valid after transfer; Android share/SAF deferred until send; folder zip on send.
- **Platforms:** Android (notifications, battery hint, share-in, native folder picker, clipboard image copy via `FileProvider`), Windows (tray, background, autostart), Linux/macOS where enabled.
- **UX:** Composer paste image, snackbars below app bar, theme modes, settings About shows version from `package_info_plus`.

### Notes

- Alpha builds are for testing; expect rough edges. Report issues via the contact on the Settings screen.

---

## Earlier

- Prior releases were not tracked in this file; see git history.
