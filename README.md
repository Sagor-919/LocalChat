# Local Chat

**Alpha 1.7.0** · Peer-to-peer LAN messenger (Flutter)

| | |
|--|--|
| **Publisher** | [RecklessGalaxy.com](https://recklessgalaxy.com) |
| **Developer** | Sagor Hossen |

This app discovers nearby devices on **Wi‑Fi / Ethernet**, opens **TCP chat** without a central server, and transfers **files** over a separate streaming channel. **Chat messages are encrypted** end-to-end for the session.

> **Alpha:** Expect bugs, unfinished polish, and breaking changes. Not for production security without your own review.

---

## Documentation

| Document | Contents |
|----------|----------|
| [**docs/FEATURES.md**](docs/FEATURES.md) | Feature-by-feature reference (what exists and where in code). |
| [**docs/RELEASE_ALPHA.md**](docs/RELEASE_ALPHA.md) | Signing, builds, release checklist. |
| [**docs/windows_share_from_explorer.md**](docs/windows_share_from_explorer.md) | Optional Explorer context menu → `--share-file` (Windows). |
| [**CHANGELOG.md**](CHANGELOG.md) | Alpha 1.7.0 notes. |
| [**docs/phases_archive.md**](docs/phases_archive.md) | Original phased implementation plan (historical). |

---

## Quick start (development)

```bash
flutter pub get
flutter analyze
flutter run
```

- **Android:** connect device or emulator with LAN access for discovery.
- **Windows:** `flutter run -d windows`

---

## Tests

```bash
flutter test
```

[`test/attachment_prepare_test.dart`](test/attachment_prepare_test.dart) covers chunked copy helpers and `uniqueTempPath`. Folder-zip tests run only when `tar` is on `PATH`.

---

## Architecture (short)

- **UDP** — discovery (`broadcast_port` / handshake in [`lib/discovery_service.dart`](lib/discovery_service.dart)).
- **TCP** — JSON chat + control; [`lib/connection_service.dart`](lib/connection_service.dart).
- **File transfer** — dedicated socket protocol; [`lib/file_transfer_service.dart`](lib/file_transfer_service.dart), [`lib/transfer_manager.dart`](lib/transfer_manager.dart).
- **Persistence** — SQLite `sqflite` ([`lib/message_store.dart`](lib/message_store.dart)); attachments on disk per app settings.
- **Crypto** — [`lib/chat_crypto.dart`](lib/chat_crypto.dart).

---

## Chat history loading

- **Initial load:** up to **100** recent messages (`_initialHistoryWindow` in [`lib/chat_screen.dart`](lib/chat_screen.dart)).
- **Visible slice:** **50**; scroll-up loads older batches of **50** (`loadOlderBatch` in [`lib/message_store.dart`](lib/message_store.dart)).

---

## Peer identity (LAN stable tag)

Devices advertise a **non-secret LAN tag** so after **clear app data** the same hardware can **merge** history with a new UUID. See [`lib/services/device_identity_service.dart`](lib/services/device_identity_service.dart) and [`lib/home_screen.dart`](lib/home_screen.dart).

---

## Android: share & attach

**Share into Local Chat:** From another app, **Share** → Local Chat. On the home screen a banner shows pending shares; open a chat to stage them. `content://` URIs are **not** fully copied until **Send** (see [`lib/android_share_inbound.dart`](lib/android_share_inbound.dart), [`MainActivity.kt`](android/app/src/main/kotlin/com/example/local_chat/MainActivity.kt)).

**Attach (paperclip):** Native SAF picker returns URIs only — no `file_picker` cache copy at pick time ([`lib/android_attachment_picker.dart`](lib/android_attachment_picker.dart)).

---

## Release builds

See [**docs/RELEASE_ALPHA.md**](docs/RELEASE_ALPHA.md) for `flutter build apk` / `appbundle` / `windows`, signing, and Play Console notes.

**Version** is defined in **`pubspec.yaml`** (`1.7.0+7` = version **1.7.0**, build **7**). Android Gradle reads it automatically. In-app **About** uses `package_info_plus` plus `AppMetadata.releaseLabel` in [`lib/app_metadata.dart`](lib/app_metadata.dart).

---

## License / copyright

Copyright (c) Sagor Hossen. See project files for third-party notices (Flutter, plugins).

---

## Repository

- Local reference clones (e.g. `_ref_lanmessenger/`) are listed in `.gitignore` and are not part of this project.
