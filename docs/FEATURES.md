# LocalChat — feature reference (1.8.0)

Maps user-visible behavior to code. For contributors and testers.

---

## Core

| Topic | Detail |
|-------|--------|
| Transport | No cloud — all traffic stays on LAN (Wi-Fi / Ethernet) |
| Discovery | UDP broadcast port 4040; peers appear within seconds |
| Chat | TCP JSON per peer, port 4041; one socket per session |
| Files | Separate ephemeral TCP connection; chunked streaming |

---

## Boot

| Feature | Behavior | Code |
|---------|----------|------|
| Splash-first | App paints splash immediately; heavy init (SQLite, sockets, notifications) runs behind it | [`lib/app_splash.dart`](../lib/app_splash.dart), [`lib/main.dart`](../lib/main.dart) |
| Parallel init | `DeviceInfo` and `MessageStore` init run concurrently | [`lib/main.dart`](../lib/main.dart) `_bootstrapServices()` |
| Boot error | If bootstrap fails, error screen shown instead of blank | [`lib/app_splash.dart`](../lib/app_splash.dart) `AppBootError` |

---

## Home screen

| Feature | Behavior | Code |
|---------|----------|------|
| Peer list | Discovered devices; refreshes on discovery/connection events | [`lib/home_screen.dart`](../lib/home_screen.dart) |
| Online status | TCP connected on chat open; list reflects state | [`lib/connection_service.dart`](../lib/connection_service.dart), [`lib/discovery_service.dart`](../lib/discovery_service.dart) |
| Identity merge | Same device after reinstall merges history via LAN stable tag | [`lib/services/device_identity_service.dart`](../lib/services/device_identity_service.dart), [`lib/message_store.dart`](../lib/message_store.dart) |

---

## Chat screen

| Feature | Behavior | Code |
|---------|----------|------|
| Text messages | Multiline composer; Enter sends on desktop; encrypted per peer | [`lib/chat_screen.dart`](../lib/chat_screen.dart), [`lib/chat_crypto.dart`](../lib/chat_crypto.dart) |
| Delivery states | Sent → confirming → delivered / undelivered | [`lib/message_model.dart`](../lib/message_model.dart) |
| History | SQLite; initial window + scroll-up pagination | [`lib/message_store.dart`](../lib/message_store.dart) |
| Attachments | Stage files; Send transmits all staged with optional caption | [`lib/chat_screen.dart`](../lib/chat_screen.dart), [`lib/transfer_manager.dart`](../lib/transfer_manager.dart) |
| File transfer UI | Progress bar, pause/cancel, failed/cancelled styling | [`lib/transfer_manager.dart`](../lib/transfer_manager.dart) |
| No-LAN guard | Attempting file send without LAN shows "File transfer needs a LAN connection"; drop target disabled | [`lib/chat_screen.dart`](../lib/chat_screen.dart) |
| Image bubbles | Thumbnails inline; tap to open; outbound files persisted to app documents | [`lib/transfer_manager.dart`](../lib/transfer_manager.dart) |
| Copy message | Long-press context menu; copy path or image bytes to clipboard | [`lib/chat_screen.dart`](../lib/chat_screen.dart) |
| Desktop drag-drop | Drop files onto composer; View in Explorer opens download folder if file missing | [`lib/chat_screen.dart`](../lib/chat_screen.dart) |
| Android | Share into app queues staged items; paste image from clipboard; locate file via Documents URI | [`android/.../MainActivity.kt`](../android/app/src/main/kotlin/com/example/local_chat/MainActivity.kt) |

---

## Attachments pipeline

| Stage | Detail | Code |
|-------|--------|------|
| Pick | Desktop: file_picker; folder → zipped at send. Android: SAF content:// deferred until send | [`lib/transfer_manager.dart`](../lib/transfer_manager.dart) |
| Prepare | Content URIs materialized to temp; duplicates deduplicated; folder zipped | [`lib/attachment_prepare.dart`](../lib/attachment_prepare.dart) |
| Persist outbound | Sent files copied to `outbound_attachments/` before DB update — survives send cleanup | [`lib/transfer_manager.dart`](../lib/transfer_manager.dart) |
| Transfer | Chunked TCP; receiver resumes to configured download folder | [`lib/file_transfer_service.dart`](../lib/file_transfer_service.dart) |

---

## Security & reliability

| Feature | Detail | Code |
|---------|--------|------|
| 1 MB line limit | Incoming TCP JSON frames > 1 MB → socket destroyed immediately | [`lib/connection_service.dart`](../lib/connection_service.dart) `_maxLineBytes` |
| Zombie socket guard | Concurrent dials to same peer deduplicated via `_connecting` set | [`lib/connection_service.dart`](../lib/connection_service.dart) `connectTo()` |
| UDP sub lifecycle | Datagram subscription stored and cancelled on rebind/stop | [`lib/discovery_service.dart`](../lib/discovery_service.dart) |
| Multicast lock | Android multicast lock released on UDP bind failure | [`lib/discovery_service.dart`](../lib/discovery_service.dart) |
| Transfer disposal | StreamControllers and notification timer disposed on app exit | [`lib/transfer_manager.dart`](../lib/transfer_manager.dart) `dispose()` |

---

## Settings

| Feature | Code |
|---------|------|
| Theme | System / light / dark | [`lib/app_settings.dart`](../lib/app_settings.dart) |
| Download folder | Default + picker; Android storage probes | [`lib/settings_screen.dart`](../lib/settings_screen.dart) |
| Android battery | Unrestricted battery hint | [`lib/android_app_control.dart`](../lib/android_app_control.dart) |
| Desktop | Run in background, start with Windows | [`lib/app_settings.dart`](../lib/app_settings.dart) |
| About | Version, publisher, developer | [`lib/settings_screen.dart`](../lib/settings_screen.dart) |

---

## Platform features

| Platform | Feature | Code |
|----------|---------|------|
| Android | Notifications, battery hint, share-in, native folder picker, clipboard image copy via FileProvider | [`lib/main.dart`](../lib/main.dart), `MainActivity.kt` |
| Windows | System tray, background mode, autostart, taskbar attention flash | [`lib/main.dart`](../lib/main.dart), [`lib/windows_taskbar_flash.dart`](../lib/windows_taskbar_flash.dart) |
| Web | UI only — LAN and SQLite features disabled via `kIsWeb` guards | throughout `lib/` |

---

## Tests

| Area | File |
|------|------|
| Attachment prepare helpers | [`test/attachment_prepare_test.dart`](../test/attachment_prepare_test.dart) |

Run: `flutter test`
