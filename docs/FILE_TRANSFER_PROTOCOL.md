# File Transfer Protocol

**Ports:** Chat/control **4041** (JSON lines), file bytes **4042** (JSON header line + binary stream).  
**Version:** As implemented after QA Items 2–4 (2026-06-04).  
**Related:** [`QA_IMPROVEMENTS_ROADMAP.md`](QA_IMPROVEMENTS_ROADMAP.md), [`FEATURES.md`](FEATURES.md)

Both peers should run the same LocalChat build for offer/accept/auth behavior. Older peers may time out waiting for `file_accept` or fail token validation.

---

## Flow overview

```text
Sender                                    Receiver
  |                                         |
  |-- file_offer (chat 4041) -------------->|
  |<-- file_accept OR file_reject ----------|  (auto or user dialog)
  |                                         |
  |-- file_notify (chat 4041) ------------->|  registerIncoming + expected token
  |                                         |
  |======== TCP connect 4042 ==============>|
  |-- JSON header (id, name, size, offset, token, ...) -->|
  |<-- START\n -----------------------------|
  |-- file bytes -------------------------->|
  |                                         |
  |-- file_control pause/resume (optional) ->|
```

**Order matters:** `file_notify` must arrive before the receiver accepts the file TCP connection (registration window).

---

## Chat socket messages (port 4041)

All are JSON objects, one per line, UTF-8.

### `file_offer` (sender → receiver)

Announces intent to send; receiver runs preflight before accepting.

```json
{
  "type": "file_offer",
  "id": "<fileId-uuid>",
  "name": "<display name or folder label>",
  "size": 12345678,
  "folderBatch": false
}
```

- `folderBatch: true` — direct folder mode (multi-file); one accept for whole batch.
- Handler: [`TransferManager.onIncomingFileOffer`](../lib/transfer_manager.dart) via [`main.dart`](../lib/main.dart).

### `file_accept` / `file_reject` (receiver → sender)

```json
{ "type": "file_accept", "id": "<fileId>" }
{ "type": "file_reject", "id": "<fileId>", "reason": "Declined" }
```

Sender waits on internal completer ([`_sendOfferAndWait`](../lib/transfer_manager.dart)).

### `file_notify` (sender → receiver)

Registers the upcoming TCP transfer.

```json
{
  "type": "file_notify",
  "id": "<fileId>",
  "name": "<file name or relative path>",
  "size": 12345,
  "offset": 0,
  "folderRoot": "OptionalFolderName",
  "batchMessageId": "<parent-id-for-subsequent-folder-files>",
  "batchTotalSize": 999999
}
```

| Field | Use |
| --- | --- |
| `offset` | Resume byte offset (sender retry/resume) |
| `folderRoot` | Direct folder mode: save under `Downloads/<folderRoot>/...` |
| `batchMessageId` | Sub-file of folder batch; no new chat row |
| `batchTotalSize` | First file only: total bytes for progress UI |

Handler: [`TransferManager.registerIncoming`](../lib/transfer_manager.dart).

### `file_control` (either direction)

Pause or resume.

```json
{
  "type": "file_control",
  "id": "<fileId>",
  "pause": true,
  "from": "sender"
}
```

| `from` | `pause: true` | `pause: false` |
| --- | --- | --- |
| `sender` | Receiver stops writing | — |
| `receiver` | Sender stops sending | Sender calls `resumeOutgoing` |

Handler: [`main.dart`](../lib/main.dart) → [`TransferManager`](../lib/transfer_manager.dart).

---

## File TCP (port 4042)

### Header (first line, JSON + `\n`)

```json
{
  "id": "<fileId>",
  "name": "<fileName or relativePath>",
  "size": 12345,
  "offset": 0,
  "token": "<64-char hex sha256>",
  "senderPeerId": "<sender userId uuid>",
  "folderRoot": "OptionalFolderName"
}
```

### Token (required on current builds)

Computed by both peers identically:

```text
ids = sort(localPeerId, remotePeerId)
token = SHA256( UTF8("localchat:file:v1:" + ids[0] + ":" + ids[1] + ":" + fileId) )
```

Implementation: [`FileTransferAuth`](../lib/file_transfer_auth.dart).

- Receiver stores expected token when `file_notify` is processed.
- Validation: [`FileReceiver.validateTransferToken`](../lib/file_transfer_service.dart) — `senderPeerId` must match registered peer; token must match.
- `isIncomingRegistered`: rejects TCP when no pending `file_notify` for `fileId`.
- Failure: socket closed, error `Rejected: invalid or missing transfer token` or `Rejected: no pending transfer for this file`.

### After header

1. Receiver validates token.
2. Receiver opens/creates destination file (respecting `folderRoot` + path segments).
3. Receiver sends `START\n`.
4. Sender streams raw bytes from `offset` to `size`.
5. Receiver writes until `size` bytes received.

Chunk size: 64 KB (`kChunkSize` in `file_transfer_service.dart`).

---

## Folder send modes

| Setting | Behavior |
| --- | --- |
| **Send folders as ZIP** (default, desktop) | One `file_offer`/`file_notify`, one TCP, one `.zip` file; temp ZIP on sender during prep |
| **Send folders as files** | One `file_offer` for batch; multiple `file_notify` + TCP; paths preserved under `folderRoot` |

**Android receiver:** direct mode not supported; sender prompted to use ZIP ([`peerReceivesFolderAsFiles`](../lib/client_platform.dart)).

---

## Receiver preflight (auto-accept)

When **Settings → Auto-accept incoming files** is on:

1. Writable probe in download folder.
2. Free space check (`preflightReceiveDestination` in [`storage_usage.dart`](../lib/storage_usage.dart)).
3. Auto `file_accept` if OK; else `file_reject` with reason.

When off: [`showIncomingFileOfferDialog`](../lib/incoming_file_offer.dart).

---

## Discovery / platform (Item 2)

UDP broadcast format (6 fields):

```text
LOCALCHAT|<userId>|<displayName>|<tcpPort>|<lanTagOr->|<platform>
```

`platform`: `android`, `windows`, `linux`, `macos`, `ios`, `web`, `unknown`.

TCP `hello` also includes `"platform": "..."` for peer metadata.

---

## Pause / resume / retry (Item 3)

| UI action | Local role | Effect |
| --- | --- | --- |
| Pause | Sender | `pauseOutgoing`, `userPaused=true`, `file_control` |
| Pause | Receiver | `pauseIncoming`, `userPaused=true`, `file_control` |
| Resume | Sender | `resumeOutgoing`, new `file_notify` with `offset` |
| Resume | Receiver | `resumeIncoming`, `file_control pause:false` |
| Retry (failed send) | Sender | Resume from offset if partial, else restart at 0 |

Auto-resume after network blip: only if **`userPaused` is false**.

---

## Orphan TCP rejection (Item 5)

- `senderPeerId` in header must match the peer from `file_notify`.
- No registration → connection closed before `START` (no chat row with `unknown` peer).

---

## Code map

| Concern | Primary file |
| --- | --- |
| Orchestration | [`lib/transfer_manager.dart`](../lib/transfer_manager.dart) |
| TCP send/receive | [`lib/file_transfer_service.dart`](../lib/file_transfer_service.dart) |
| Auth token | [`lib/file_transfer_auth.dart`](../lib/file_transfer_auth.dart) |
| Folder enumeration | [`lib/folder_send.dart`](../lib/folder_send.dart) |
| Chat dispatch | [`lib/main.dart`](../lib/main.dart) |
| UI controls | [`lib/chat_screen.dart`](../lib/chat_screen.dart) |
