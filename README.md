# LocalChat

LAN peer-to-peer chat and file transfer. No server, no accounts, and no internet required after install.

LocalChat is a Flutter app for nearby devices on the same Wi-Fi or Ethernet network. Peers discover each other with UDP broadcast, chat over TCP, and transfer files directly over LAN.

## Current Status

- Alpha release: `1.8.0+8`
- Primary target: Android and desktop
- Repository status: being prepared for open source
- Package publishing: disabled with `publish_to: none`

## Features

- Automatic LAN discovery over UDP broadcast
- Encrypted one-to-one chat between peer pairs
- SQLite chat history with recent-window loading and older-message paging
- Message delivery states: sent, confirming, delivered, undelivered
- Chronological message ordering with deterministic tie-breaks
- Chunked TCP file transfer with progress, cancel, retry-related state, and internal pause/resume recovery
- Multiple staged attachments with optional captions
- Folder send on desktop by zipping the folder before transfer
- Inline image thumbnails, image clipboard paste, and open/copy actions
- Android share-in from other apps, native attachment picker, gallery picker, and storage helpers
- Desktop drag and drop on the chat screen and home screen staging queue
- Windows system tray, hide-to-tray behavior, autostart setting, taskbar progress pulse, and native taskbar flash
- Theme modes: system, light, and dark

## Platform Support

| Platform | Status | Notes |
| --- | --- | --- |
| Android | Primary | LAN chat, file transfer, notifications, share-in, picker/gallery flows, battery optimization prompt |
| Windows | Supported | LAN chat, file transfer, tray/background mode, autostart, taskbar attention, Explorer context-menu handoff |
| Linux | Supported | LAN chat, file transfer, tray-capable desktop flow where supported |
| macOS | Supported | LAN chat and file transfer; platform behavior depends on local permissions |
| Web | Experimental preview | Browser builds are not a supported runtime for LAN sockets or SQLite-backed local storage |

## Important Limitations

- LocalChat only discovers peers on the same LAN broadcast domain. It does not relay through the cloud or pair across the internet.
- Android background reliability is controlled by the OS and vendor battery policy. The app asks for unrestricted battery usage and uses wakelock while active TCP peers exist, but it does not currently run a dedicated Android foreground service.
- Windows Explorer sharing is implemented through a command-line handoff (`--share-file`) and optional user registry entry, not the Microsoft Store Share contract.
- Web builds are experimental. Some unsupported browser paths may show the boot error screen rather than the full app.

## Requirements

- Flutter SDK on the stable channel
- Dart SDK 3.x, included with Flutter
- Platform toolchains for the target you build:
  - Android Studio / Android SDK for Android
  - Visual Studio with desktop C++ workload for Windows
  - Linux desktop dependencies for Linux
  - Xcode for macOS / iOS

## Setup

```bash
git clone https://github.com/Reckless2077/LocalChat.git
cd LocalChat
flutter pub get
flutter test
flutter analyze
```

## Run

```bash
flutter run -d android
flutter run -d windows
flutter run -d linux
flutter run -d macos
flutter run -d chrome
```

Windows helper scripts are also included:

```bat
run_android_usb.bat
run_web_chrome.bat [port]
```

## Build

```bash
flutter build apk --release
flutter build appbundle --release
flutter build windows
flutter build linux
flutter build macos
```

Android release builds currently use the debug signing config in `android/app/build.gradle.kts`. Replace that with a real release signing config before distributing APK or AAB builds.

## Network Model

| Purpose | Transport | Port |
| --- | --- | --- |
| Discovery | UDP broadcast | 4040 |
| Chat/control | TCP JSON lines | 4041 |
| File transfer | TCP stream | 4042 |

All traffic is intended to stay on the local network. There is no backend service.

## Project Structure

```text
lib/
  main.dart                       App bootstrap, lifecycle, notifications, tray integration
  discovery_service.dart          UDP LAN discovery
  connection_service.dart         TCP chat/control sockets, heartbeat, delivery acks
  chat_screen.dart                Conversation UI, composer, staging, drag/drop
  chat_message_ordering.dart      Shared chronological ordering comparator
  message_store.dart              SQLite persistence and history windows
  transfer_manager.dart           File transfer orchestration
  file_transfer_service.dart      Low-level TCP file send/receive
  attachment_prepare.dart         Copy/materialize/zip helpers before sending
  android_share_inbound.dart      Android share queue bridge
  staged_from_drop.dart           Desktop/Android drop-to-staging helpers
  windows_taskbar_flash.dart      Conditional Windows taskbar attention adapter

android/
  app/src/main/kotlin/...         Android method channels, share-in, clipboard/file helpers

docs/
  FEATURES.md                     Verified feature map with code pointers
  windows_share_from_explorer.md  Optional Windows Explorer context-menu setup

test/
  attachment_prepare_test.dart
  chat_message_ordering_test.dart
  staged_from_drop_test.dart
```

## Verification

```bash
flutter test
flutter analyze
```

Current tests cover attachment preparation, folder zipping, dropped-file staging, and deterministic chat message ordering.

## Contributing

1. Fork the repository and create a branch from `main`.
2. Keep pull requests focused on one concern.
3. Run `flutter test` and `flutter analyze` before opening a PR.
4. Update `README.md` or `docs/FEATURES.md` when behavior changes.

## License

LocalChat is open source under the [MIT License](LICENSE).

**Publisher:** RecklessGalaxy.com

**Developer:** Sagor Hossen
