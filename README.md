GOAL:
Build a simple, fast, peer-to-peer LAN messaging app using Flutter that automatically discovers nearby devices, allows one-tap chat, and supports file/image sharing with a Messenger-style UI.

CORE PRINCIPLES:

No server (pure LAN / P2P)
Fast and lightweight
Stable file transfer (chunked streaming)
Clean, modern UI (Messenger-like)
Cross-platform (Android + Desktop)
PHASE 1 — PROJECT SETUP
Create Flutter project
Enable desktop support (Windows)
Setup folder structure:
/core (networking, models)
/features (chat, discovery, transfer)
/ui (screens, widgets)
Add dependencies:
provider / riverpod (state)
file_picker
desktop_drop (desktop only)
Setup basic navigation

OUTPUT:

App launches with empty home screen
PHASE 2 — DEVICE DISCOVERY (UDP)

GOAL: Automatically detect nearby devices on LAN

IMPLEMENT:

Use UDP broadcast (e.g., port 45454)
Send DISCOVER message every few seconds:
{ "type": "DISCOVER", "name": deviceName }
Listen for incoming DISCOVER messages
Respond with:
{ "type": "RESPONSE", "name": deviceName, "ip": localIP }
Maintain in-memory list of active devices
Remove inactive devices after timeout

UI:

Home screen shows list of nearby devices
Auto-refresh list

OUTPUT:

Devices appear/disappear in real-time
PHASE 3 — CONNECTION + CHAT (TCP)

GOAL: Tap device → start chat session

IMPLEMENT:

On tap → create TCP connection (fixed port)
Exchange handshake:
{ "type": "HELLO", "name": deviceName }
Maintain persistent socket per peer
Send/receive messages as JSON:
{ "type": "MESSAGE", "text": "...", "timestamp": ... }

UI:

Messenger-style chat screen
Message bubbles (left/right)
Input field + send button

OUTPUT:

Real-time messaging between devices
PHASE 4 — FILE TRANSFER (CORE FEATURE)

GOAL: Send files reliably (like LAN Messenger)

IMPLEMENT:

Separate TCP channel OR reuse connection
Handshake before transfer:
{ "type": "FILE_META", "name": "...", "size": ... }
Receiver replies: "START"

SENDING LOGIC:

Read file in 64KB chunks
Send chunk
WAIT for socket flush before next
Repeat until done

RECEIVING LOGIC:

Continuously read bytes
Append to file
Track progress

FAILSAFE:

Timeout if no progress (10–15 sec)
Cancel and clean partial file

OUTPUT:

Stable large file transfer (no freezing)
PHASE 5 — IMAGE PREVIEW

GOAL: Show images inside chat

IMPLEMENT:

Detect file type (image vs other)
If image:
Show thumbnail in chat bubble
Tap to open full-screen preview
Cache received images locally

UI:

Messenger-style image bubble
Fullscreen viewer

OUTPUT:

Smooth image preview experience
PHASE 6 — DRAG & DROP + PICKER

GOAL: Easy file sending

DESKTOP:

Drag & drop files into chat (desktop_drop)

ANDROID:

File picker button

COMMON:

Show selected file preview before sending

OUTPUT:

Simple and intuitive file sharing
PHASE 7 — STABILITY & PERFORMANCE

IMPLEMENT:

Chunk-based transfer (64KB)
Backpressure handling (await socket flush)
Prevent UI blocking (async / isolate if needed)
Connection retry logic
Proper error handling

OUTPUT:

No freeze, no crash on large files
PHASE 8 — POLISH
Show online/offline status
Progress bar for file transfer
Typing indicator (optional)
Dark/light theme
Device rename

OUTPUT:

Production-like experience
FUTURE UPGRADES (OPTIONAL)
Resume interrupted transfer
Multi-device group chat
Encryption (AES)
QR code connection fallback
WebRTC upgrade
FINAL RESULT:

A clean, stable LAN messenger with:

Auto device discovery
1-tap chat
Messenger UI
Reliable file transfer
Image preview

---

## Automated tests (attachments)

Run:

`flutter test`

[`test/attachment_prepare_test.dart`](test/attachment_prepare_test.dart) covers chunked copy (progress, missing file, cancel) and `uniqueTempPath`. The folder-zip test runs only when `tar` is on `PATH` (otherwise it is skipped).

## Chat history loading and session cache

- **Initial load:** Opening a chat loads at most **25** recent messages from SQLite (`_pageSize`, `_initialHistoryWindow`, and `_historyBatchSize` in [`lib/chat_screen.dart`](lib/chat_screen.dart)). This keeps first paint light on long threads.
- **Pagination:** The list shows a sliding slice of loaded messages; scrolling up reveals older ones in batches of 25. When in-memory history is exhausted but the database has more, the screen loads older rows via `loadOlderBatch` in [`lib/message_store.dart`](lib/message_store.dart).
- **Reopen without a full disk reload:** On `dispose`, [`ChatSessionCache`](lib/chat_session_cache.dart) stores a snapshot of the session. When you open the same chat again, if the peer’s **message count in the DB matches** the cached total, the UI restores from cache and skips reloading history from SQLite. If the count changed (new messages while you were away), history is loaded from the database again.
- **Clear chat:** Clearing the chat invalidates the session cache for that peer so the next open does not show stale data.

## Manual QA — deferred attachments and Android share

**Deferred send (composer):** Stage files or a folder from pickers / desktop drag-drop. Confirm no heavy work until Send: folder should not create a zip until send; duplicate paths in one batch should show **Preparing…** (copy) then **Sending…**. Cancel during prep should stop and clean up.

**Large file:** Send a multi-GB file if possible; UI should stay responsive and progress should update.

**Android — share into Local Chat (critical):** From another app, use *Share* and choose Local Chat.

1. If you are on the **home** screen, you should see a banner like *"N file(s) shared — open a chat to attach"* (see [`lib/home_screen.dart`](lib/home_screen.dart) and [`lib/android_share_inbound.dart`](lib/android_share_inbound.dart)).
2. Open a chat: [`ChatScreen`](lib/chat_screen.dart) calls `AndroidShareInbound.attachChat` and `syncFromNative`; shared items appear in the **staged row** right away. For typical `content://` shares, only the URI + display name are queued (**no full-file copy** until Send — see [`MainActivity.kt`](android/app/src/main/kotlin/com/example/local_chat/MainActivity.kt) `describeShareForDart` vs `materializeContentUriToFile`).
3. Tap **Send**: the bubble shows **Preparing…** while the provider stream is copied to a temp file, then **Sending…** for the normal TCP transfer.

Cold start and resume also call `syncFromNative` from [`lib/main.dart`](lib/main.dart) so intents are not lost if the activity was recreated.

## Peer identity and deduplication (LAN stable tag)

- Each device computes a **non-secret LAN tag** (`DeviceInfo.lanStableTag`) from OS-level identifiers via [`lib/services/device_identity_service.dart`](lib/services/device_identity_service.dart) and advertises it in UDP discovery (`LOCALCHAT|userId|name|port|tag`). See [`lib/discovery_service.dart`](lib/discovery_service.dart).
- The prefs UUID (`device_id`) is still the **protocol peer id** for TCP/chat; after a neighbor **clears app data** they get a new UUID but usually the **same LAN tag** on the same hardware.
- The **viewer’s** SQLite DB stores `lan_stable_tag` on the `peers` row ([`lib/message_store.dart`](lib/message_store.dart)). When a discovered peer’s tag matches an older peer id, history is **merged** into the new id (`mergePeerLanIdentity`) and the old TCP slot is disconnected — see [`lib/home_screen.dart`](lib/home_screen.dart) `_applyDiscoverySavesAndRefresh`.
- **Fast reconnect UI:** [`ConnectionService`](lib/connection_service.dart) exposes `disconnectedPeerEvents` so the home list refreshes as soon as chat TCP drops, not only after UDP stale timing.
- **Limits:** Merge by tag requires the older `peers` row to have been saved with a tag (this build or later). Legacy rows with only a UUID cannot auto-merge. Very old Android peers that omit the 5th discovery field still work; the tag is optional on the wire.