# LocalChat

**LAN peer-to-peer chat and file transfer. No server. No internet required.**

Works on Android, Windows, Linux, macOS. Peers discover each other automatically via UDP broadcast on the same Wi-Fi or Ethernet network.

---

## Features

- **Instant discovery** — UDP broadcast; peers appear on the home screen within seconds
- **Encrypted chat** — end-to-end encrypted messages per peer pair
- **File transfer** — chunked TCP streaming with progress, pause/resume, cancel
- **Folder send** — zips folders automatically before transfer
- **Offline history** — SQLite message store with full chat history
- **Delivery states** — sent → delivered confirmation handshake
- **Notifications** — incoming message and file alerts (Android, Windows)
- **Android** — share-in from other apps, native folder picker, battery hint, background service
- **Windows** — system tray, hide-to-tray, autostart, taskbar attention flash
- **Themes** — system / light / dark

---

## Platforms

| Platform | Status |
|----------|--------|
| Android | ✅ Primary |
| Windows | ✅ Supported |
| Linux | ✅ Supported |
| macOS | ✅ Supported |
| Web | ⚠️ UI only (no LAN, no SQLite) |

---

## Building

### Prerequisites

- Flutter SDK (stable channel)
- Dart SDK 3.x (included with Flutter)

### Android

```bash
# Debug
flutter run -d <device-id>

# Release APK
flutter build apk --release

# Release AAB
flutter build appbundle --release
```

> Release signing requires `android/key.properties`. Copy from `android/key.properties.example` and fill in your keystore values.

### Windows / Linux / macOS

```bash
flutter run -d windows    # or linux / macos
flutter build windows     # or linux / macos
```

### Helpers (Windows)

```bat
run_android_usb.bat       # auto-detects USB Android device
run_web_chrome.bat [port] # Chrome web preview (feature-limited)
```

---

## Project structure

```
lib/
  main.dart                    # App entry, bootstrap, lifecycle
  connection_service.dart      # TCP chat sessions, heartbeat
  discovery_service.dart       # UDP broadcast discovery
  transfer_manager.dart        # File transfer orchestration
  file_transfer_service.dart   # Low-level chunked TCP send/receive
  message_store.dart           # SQLite persistence
  chat_crypto.dart             # Message encryption
  chat_screen.dart             # Conversation UI
  home_screen.dart             # Peer list
  settings_screen.dart         # Settings
  app_settings.dart            # SharedPreferences wrapper
  device.dart                  # DeviceInfo / PeerDevice models
  services/
    device_identity_service.dart  # LAN stable tag for peer dedup
  ...                          # Platform adapters, models, utilities
test/                          # Unit tests
docs/
  FEATURES.md                  # Feature reference with code pointers
  windows_share_from_explorer.md
android/
  key.properties.example       # Keystore config template
```

---

## Architecture notes

- **No backend** — all traffic stays on LAN. No accounts, no cloud.
- **Discovery**: UDP port 4040, TCP chat/control port 4041, TCP file transfer on ephemeral port.
- **Peer identity**: UUID per install stored in SharedPreferences. LAN stable tag (device fingerprint) enables history merge after reinstall.
- **Encryption**: symmetric key derived from peer ID pair; see `lib/chat_crypto.dart`.
- **File transfer**: negotiated on the chat TCP socket (`file_notify`), transferred on a separate TCP connection managed by `FileReceiver`/`FileSender`.

---

## Contributing

1. Fork and create a branch off `main`
2. Run `flutter analyze` and `flutter test` before opening a PR
3. Keep PRs focused — one concern per PR

---

**Publisher:** RecklessGalaxy.com · **Developer:** Sagor Hossen
