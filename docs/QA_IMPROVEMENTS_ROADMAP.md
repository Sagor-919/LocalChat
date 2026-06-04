# QA Improvements Roadmap

**Purpose:** Preserve the step-by-step improvement plan and implementation status across chat sessions (context compaction).  
**Process:** One item at a time — user replies **Yes** / **No** / **Later** / **Yes, but smaller** before coding.  
**Last updated:** 2026-06-04 (Items 1–28 complete on branch `feature/qa-improvements-roadmap`)

---

## How to resume work (for agents)

1. Read this file and [`FILE_TRANSFER_PROTOCOL.md`](FILE_TRANSFER_PROTOCOL.md).
2. Find the first row in **Status tracker** marked **Pending** or **Next**.
3. Present that item to the user for approval (one item only).
4. After implementation: mark **Done**, list files touched, run `flutter test` + `flutter analyze`, update [`FEATURES.md`](FEATURES.md) if user-visible behavior changed.
5. Do **not** skip ahead without user approval unless they say “move forward” on the current item.

---

## Status tracker

| # | Item | Priority | Status | Notes |
| --- | --- | --- | --- | --- |
| 1 | Storage transparency + temp cleanup (folder ZIP orphans) | P0 | **Done** | Settings → Storage; folder size warnings |
| 2 | Receiver preflight + auto-accept + folder send modes + Android→ZIP prompt | P0/P1 | **Done** | Merged with user refinements during Item 2 discussion |
| 3 | Pause / Resume / Retry UI + fix auto-resume on user pause | P1 | **Done** | Chat bubble actions; `file_control` resume |
| 4 | File port auth token (TCP header) | P2 | **Done** | `FileTransferAuth`; reject bad token |
| 5 | Reject orphan file TCP (no pending `file_notify`) | P2 | **Done** | `senderPeerId` + registration gate |
| 6 | Transfer center (global active/paused/failed list) | P2 | **Done** | `TransferCenterScreen` |
| 7 | Accept/decline UI in notification (large files) | P2 | **Done** | Android notif when manual accept + ≥5MB |
| 8 | Encrypt file bytes on wire | P3 | **Done** | AES-GCM per chunk (Settings toggle) |
| 9 | Stream folder without full ZIP (long-term) | P3 | **Done** | Direct multi-file mode (Item 2) |
| 10 | Clear chat history deletes attachment files on disk | P2 | **Done** | `message_attachment_cleanup.dart` |
| 11 | Startup scan for orphaned temp ZIPs after crash | P2 | **Done** | `cleanLocalChatTempPrepArtifacts` on boot |
| 12 | IPv6 / dual-stack discovery | P3 | **Done** | IPv6 socket + `ff02::1` broadcast |
| 13 | File channel rate limit / max concurrent | P2 | **Done** | Max concurrent sends setting |
| 14 | Integration tests for TransferManager | P2 | **Done** | `transfer_manager_test.dart` + crypto/signing tests |
| 15 | Legacy peer: ZIP prompt when platform unknown | P2 | **Done** | Explicit `unknown` copy in folder ZIP dialog |
| 16 | Android foreground service for long transfers | P2 | **Done** | Wakelock + ongoing transfer notification |
| 17 | Checksum / chunk ACK after resume | P3 | **Done** | Optional SHA-256 footer |
| 18 | Bandwidth throttle setting | P3 | **Done** | KB/s throttle on send |
| 19 | QR / short-code peer verification | P3 | **Done** | Peer ID sheet + copy (manual verify) |
| 20 | Signed discovery payloads | P3 | **Done** | HMAC on UDP when secret configured |
| 21 | Export/import settings | P3 | **Done** | JSON export/import in Settings |
| 22 | Move downloads + migrate files | P3 | **Done** | `setDownloadPathWithMigration` |
| 23 | Web target: remove or hard-gate | P3 | **Done** | Web shows unsupported message |
| 24 | Windows Share contract (not only `--share-file`) | P3 | **Done** | `--share-folder` CLI arg |
| 25 | Refactor `chat_screen.dart` / `main.dart` protocol wiring | P3 | **Done** | `ChatProtocolHandler` |
| 26 | Debug log export from Settings | P3 | **Done** | `DebugLog` ring buffer |
| 27 | Max attachment size setting | P3 | **Done** | Settings MB cap |
| 28 | Partial download inventory + auto-expire | P2 | **Done** | Scan `.part` / 7-day expire |

---

## Completed items (implementation summary)

### Item 1 — Storage transparency + temp cleanup

**User problem:** Folder send builds a full `.zip` in system temp; users did not know disk was used; failed sends left orphans.

**Shipped:**

- **Settings → Storage:** temp prep archives, sent copies (`outbound_attachments`), downloads, DB size; Refresh + **Clean temp archives**.
- **Folder staging:** background size estimate; staged tile shows size + “Temp ZIP”.
- **Send confirm:** dialog when folder ≥ 500 MB or low free space on temp drive (ZIP mode).
- **Code:** [`lib/storage_usage.dart`](../lib/storage_usage.dart), [`lib/settings_screen.dart`](../lib/settings_screen.dart), [`lib/chat_screen.dart`](../lib/chat_screen.dart).
- **Tests:** [`test/storage_usage_test.dart`](../test/storage_usage_test.dart).

**Constants:** `kFolderSendConfirmThresholdBytes` (500 MB), `kFolderZipHeadroomBytes` (64 MB) in `storage_usage.dart`.

---

### Item 2 — Preflight, auto-accept, folder modes, Android ZIP

**User refinements:**

- **Auto-accept incoming files** on Settings (default **on**); no size cap when on.
- **Send folders as ZIP** toggle (desktop, default **on**); off = direct multi-file layout.
- **Android receivers:** if sender uses “files” mode, prompt **Send as ZIP?** (Cancel / Send as ZIP only).

**Shipped:**

- Chat messages: `file_offer` → `file_accept` / `file_reject` → `file_notify` → TCP (see protocol doc).
- Receiver preflight: writable download folder + free space (`preflightReceiveDestination` in `storage_usage.dart`).
- **Direct folder send:** walks tree, one TCP per file, `folderRoot` + relative paths on receiver.
- **Platform in discovery:** UDP field + `hello.platform`; [`lib/client_platform.dart`](../lib/client_platform.dart).
- **Code:** [`lib/transfer_manager.dart`](../lib/transfer_manager.dart), [`lib/folder_send.dart`](../lib/folder_send.dart), [`lib/incoming_file_offer.dart`](../lib/incoming_file_offer.dart), [`lib/app_settings.dart`](../lib/app_settings.dart).
- **Tests:** [`test/folder_send_test.dart`](../test/folder_send_test.dart), [`test/client_platform_test.dart`](../test/client_platform_test.dart).

**Settings keys:** `auto_accept_incoming_files`, `folder_send_as_zip`.

---

### Item 3 — Pause / Resume / Retry UI

**User problem:** Protocol supported pause/resume/retry but UI only had Cancel; outgoing auto-resumed after 400 ms even when user wanted pause.

**Shipped:**

- **Active transfer:** Pause + Cancel.
- **Paused:** Resume + Cancel; label “Paused” when `userPaused`.
- **Failed outgoing:** Retry + Dismiss.
- **`userPaused` flag:** blocks automatic resume after `TransferPausedException`.
- **`file_control` with `pause: false`:** resume handshake (receiver → sender `resumeOutgoing`, etc.).
- **`resumeIncoming`** for receiver-side resume.
- **`retry`:** uses offset resume when `transferredBytes > 0`.
- **Code:** [`lib/transfer_manager.dart`](../lib/transfer_manager.dart), [`lib/chat_screen.dart`](../lib/chat_screen.dart), [`lib/main.dart`](../lib/main.dart), [`lib/file_transfer_service.dart`](../lib/file_transfer_service.dart).

---

### Item 4 — File port authentication

**User problem:** Port 4042 accepted any TCP with a guessed `fileId`.

**Shipped:**

- Token: `SHA256("localchat:file:v1:{sortedPeer0}:{sortedPeer1}:{fileId}")` — [`lib/file_transfer_auth.dart`](../lib/file_transfer_auth.dart).
- Sender includes `"token"` in file TCP JSON header.
- Receiver registers expected token on `file_notify`; validates before `START`.
- Missing/wrong token → reject (`Rejected: invalid or missing transfer token`).
- **Tests:** [`test/file_transfer_auth_test.dart`](../test/file_transfer_auth_test.dart).

**Limitation (documented in SECURITY.md spirit):** LAN observer who knows both peer UUIDs + `fileId` can compute token; stops blind port 4042 connections only.

---

### Item 5 — Reject orphan file TCP

**Shipped:** `senderPeerId` in TCP header; validator matches registered peer; `isIncomingRegistered` before file write; orphan receive path deletes partial file; 800ms notify wait then abort.

---

## Key files index (post Items 1–4)

| Area | Files |
| --- | --- |
| Storage / preflight | `lib/storage_usage.dart` |
| Folder direct send | `lib/folder_send.dart` |
| Platform detection | `lib/client_platform.dart` |
| File auth token | `lib/file_transfer_auth.dart` |
| Transfer orchestration | `lib/transfer_manager.dart` |
| TCP file I/O | `lib/file_transfer_service.dart` |
| Chat protocol dispatch | `lib/main.dart` |
| Settings | `lib/app_settings.dart`, `lib/settings_screen.dart` |
| Chat UI (transfers) | `lib/chat_screen.dart` |
| Discovery + platform | `lib/discovery_service.dart`, `lib/connection_service.dart`, `lib/device.dart` |

---

## Verification (always run after a item)

```bash
flutter test
flutter analyze
```

**Current test files (28 tests):**

- `test/attachment_prepare_test.dart`
- `test/chat_message_ordering_test.dart`
- `test/staged_from_drop_test.dart`
- `test/storage_usage_test.dart`
- `test/folder_send_test.dart`
- `test/client_platform_test.dart`
- `test/file_transfer_auth_test.dart`
- `test/file_transfer_registration_test.dart`
- `test/file_transfer_crypto_test.dart`
- `test/discovery_signing_test.dart`
- `test/transfer_manager_test.dart`

---

## Original improvement themes (backlog reference)

Full brainstorm from initial codebase review; items above are the prioritized subset. Unscheduled ideas remain in backlog rows 6–28 and include: transfer center, partial download list, DB clear deletes files, cancel mid-zip, max file size, observability, refactor god files, etc.

When adding new rows, append to **Status tracker** and keep **Completed items** section updated.
