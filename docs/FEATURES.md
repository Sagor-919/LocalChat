# LocalChat Feature Reference

Verified against the codebase for version `1.8.0+8`.

This document maps user-visible behavior to implementation files so contributors can keep documentation and code in sync.

## Core Runtime

| Area | Behavior | Code |
| --- | --- | --- |
| App bootstrap | Paints a splash first, then initializes settings, identity, SQLite, sockets, notifications, tray integration, and onboarding | [`lib/main.dart`](../lib/main.dart), [`lib/app_splash.dart`](../lib/app_splash.dart) |
| Settings | SharedPreferences-backed theme, download folder, desktop background mode, and autostart values | [`lib/app_settings.dart`](../lib/app_settings.dart), [`lib/settings_screen.dart`](../lib/settings_screen.dart) |
| Identity | Per-install UUID plus a LAN-stable device tag used to merge peers after reinstall | [`lib/device.dart`](../lib/device.dart), [`lib/services/device_identity_service.dart`](../lib/services/device_identity_service.dart), [`lib/message_store.dart`](../lib/message_store.dart) |
| Web status | Web builds are experimental; unsupported LAN/socket/SQLite paths can still fall back to the boot error screen | [`lib/main.dart`](../lib/main.dart), [`lib/app_splash.dart`](../lib/app_splash.dart) |

## LAN Discovery and Chat

| Area | Behavior | Code |
| --- | --- | --- |
| Discovery | UDP broadcast on port 4040 advertises peers on the same LAN | [`lib/discovery_service.dart`](../lib/discovery_service.dart) |
| Peer list | Home screen shows discovered peers, connectivity state, unread counts, last-message previews, Android shared-file queue, and home-screen drop queue | [`lib/home_screen.dart`](../lib/home_screen.dart) |
| Chat socket | TCP JSON-line chat/control socket on port 4041 with heartbeat/liveness handling | [`lib/connection_service.dart`](../lib/connection_service.dart) |
| Delivery state | Outgoing text moves through sent/confirming/delivered/undelivered states | [`lib/message_model.dart`](../lib/message_model.dart), [`lib/chat_screen.dart`](../lib/chat_screen.dart), [`lib/message_store.dart`](../lib/message_store.dart) |
| Encryption | Chat payloads are encrypted with a key derived from the peer ID pair | [`lib/chat_crypto.dart`](../lib/chat_crypto.dart) |

## Message History and Ordering

| Area | Behavior | Code |
| --- | --- | --- |
| Store | SQLite stores messages, peers, delivery state, attachment metadata, and transfer-dismissed state | [`lib/message_store.dart`](../lib/message_store.dart) |
| Recent window | Chat opens with a recent message window and loads older batches while scrolling upward | [`lib/message_store.dart`](../lib/message_store.dart), [`lib/chat_screen.dart`](../lib/chat_screen.dart) |
| Ordering | Messages sort by timestamp, then incoming before outgoing, then ID | [`lib/chat_message_ordering.dart`](../lib/chat_message_ordering.dart), [`lib/message_store.dart`](../lib/message_store.dart), [`lib/chat_screen.dart`](../lib/chat_screen.dart) |
| Outgoing timestamps | New local messages are assigned timestamps strictly after the current thread maximum and local send sequence | [`lib/chat_screen.dart`](../lib/chat_screen.dart) |
| Regression test | Equal timestamp replies order incoming before outgoing | [`test/chat_message_ordering_test.dart`](../test/chat_message_ordering_test.dart) |

## Composer and Attachments

| Area | Behavior | Code |
| --- | --- | --- |
| Composer | Multiline text input with short hints: `Message` or `Optional caption...` | [`lib/chat_screen.dart`](../lib/chat_screen.dart) |
| Staging strip | Staged files appear above the composer with a clear-all action and per-item remove button | [`lib/chat_screen.dart`](../lib/chat_screen.dart) |
| File picker | Desktop/mobile file picker stages regular files | [`lib/chat_screen.dart`](../lib/chat_screen.dart), [`lib/deferred_staged_file.dart`](../lib/deferred_staged_file.dart) |
| Folder picker | Desktop folder picker stages a folder-to-zip transfer | [`lib/chat_screen.dart`](../lib/chat_screen.dart), [`lib/attachment_prepare.dart`](../lib/attachment_prepare.dart) |
| Android picker | Android native attachment picker returns deferred `content://` entries where needed | [`lib/android_attachment_picker.dart`](../lib/android_attachment_picker.dart), [`android/app/src/main/kotlin/com/example/local_chat/MainActivity.kt`](../android/app/src/main/kotlin/com/example/local_chat/MainActivity.kt) |
| Clipboard image paste | Desktop button and Android/desktop context menu can stage image data from the clipboard | [`lib/chat_screen.dart`](../lib/chat_screen.dart), [`android/app/src/main/kotlin/com/example/local_chat/MainActivity.kt`](../android/app/src/main/kotlin/com/example/local_chat/MainActivity.kt) |
| Android paste menu | Android uses `CupertinoTextSelectionToolbar` so long-press paste stays compact instead of showing a large Material backdrop | [`lib/chat_screen.dart`](../lib/chat_screen.dart) |
| No-LAN guard | File send and chat drop target are disabled unless the peer has an active chat/control connection | [`lib/chat_screen.dart`](../lib/chat_screen.dart) |

## File Transfer

| Area | Behavior | Code |
| --- | --- | --- |
| Negotiation | `file_offer` → `file_accept`/`file_reject` → `file_notify`; bytes on TCP port 4042 | [`docs/FILE_TRANSFER_PROTOCOL.md`](FILE_TRANSFER_PROTOCOL.md), [`lib/transfer_manager.dart`](../lib/transfer_manager.dart), [`lib/main.dart`](../lib/main.dart) |
| TCP auth | SHA256 token per `fileId` + peer pair in file header; reject if missing/wrong | [`lib/file_transfer_auth.dart`](../lib/file_transfer_auth.dart), [`lib/file_transfer_service.dart`](../lib/file_transfer_service.dart) |
| Chunked streaming | Progress, cancel, pause/resume/retry in chat UI; offset resume on TCP | [`lib/file_transfer_service.dart`](../lib/file_transfer_service.dart), [`lib/transfer_manager.dart`](../lib/transfer_manager.dart), [`lib/chat_screen.dart`](../lib/chat_screen.dart) |
| Folder ZIP mode | Desktop folder → temp ZIP (background isolate) → single file send | [`lib/attachment_prepare.dart`](../lib/attachment_prepare.dart), [`lib/transfer_manager.dart`](../lib/transfer_manager.dart) |
| Folder direct mode | Settings toggle off ZIP: multi-file send with `folderRoot` paths (desktop peers) | [`lib/folder_send.dart`](../lib/folder_send.dart), [`lib/client_platform.dart`](../lib/client_platform.dart) |
| Android folder | Prompt sender to ZIP when receiver is Android / unsupported platform | [`lib/chat_screen.dart`](../lib/chat_screen.dart) |
| Auto-accept | Settings toggle; preflight write + free space before `file_accept` | [`lib/app_settings.dart`](../lib/app_settings.dart), [`lib/storage_usage.dart`](../lib/storage_usage.dart) |
| Storage UI | Settings → Storage: sizes, clean temp prep archives | [`lib/storage_usage.dart`](../lib/storage_usage.dart), [`lib/settings_screen.dart`](../lib/settings_screen.dart) |
| Android shares | Shared `content://` files queued; materialized at send time | [`lib/android_share_inbound.dart`](../lib/android_share_inbound.dart) |
| Outbound persistence | Sent attachments copied to app documents | [`lib/transfer_manager.dart`](../lib/transfer_manager.dart) |
| Download folder | Configurable path; default `LocalChat Folder/Downloads` | [`lib/app_settings.dart`](../lib/app_settings.dart), [`lib/settings_screen.dart`](../lib/settings_screen.dart) |
| Peer platform | UDP + `hello` advertise `android`/`windows`/etc. | [`lib/discovery_service.dart`](../lib/discovery_service.dart), [`lib/connection_service.dart`](../lib/connection_service.dart) |

## Drag, Drop, and Share-In

| Area | Behavior | Code |
| --- | --- | --- |
| Whole chat drop target | The chat route wraps the screen in a `DropTarget`, not only the composer | [`lib/chat_screen.dart`](../lib/chat_screen.dart) |
| Home drop queue | Dropping files on the home screen queues them; opening a chat stages them in the composer | [`lib/home_screen.dart`](../lib/home_screen.dart), [`lib/desktop_drop_queue.dart`](../lib/desktop_drop_queue.dart), [`lib/staged_from_drop.dart`](../lib/staged_from_drop.dart) |
| Android modern drop | `content://` drop paths are accepted and staged as deferred Android content files | [`lib/staged_from_drop.dart`](../lib/staged_from_drop.dart), [`test/staged_from_drop_test.dart`](../test/staged_from_drop_test.dart) |
| Android share sheet | `ACTION_SEND` and `ACTION_SEND_MULTIPLE` intents queue inbound files | [`android/app/src/main/AndroidManifest.xml`](../android/app/src/main/AndroidManifest.xml), [`android/app/src/main/kotlin/com/example/local_chat/MainActivity.kt`](../android/app/src/main/kotlin/com/example/local_chat/MainActivity.kt), [`lib/android_share_inbound.dart`](../lib/android_share_inbound.dart) |
| Windows Explorer handoff | `--share-file <path>` queues a file from a Windows context-menu registry entry | [`lib/main.dart`](../lib/main.dart), [`docs/windows_share_from_explorer.md`](windows_share_from_explorer.md) |

## Notifications and Background Behavior

| Area | Behavior | Code |
| --- | --- | --- |
| Notifications | Incoming message/file notifications are initialized during app bootstrap | [`lib/main.dart`](../lib/main.dart) |
| Snackbar placement | Floating snackbars are positioned below the app bar and above the Android keyboard viewport | [`lib/app_snackbar.dart`](../lib/app_snackbar.dart) |
| Android battery prompt | First launch and settings can request ignore-battery-optimizations permission | [`lib/first_launch_prompt.dart`](../lib/first_launch_prompt.dart), [`lib/android_app_control.dart`](../lib/android_app_control.dart), [`android/app/src/main/kotlin/com/example/local_chat/MainActivity.kt`](../android/app/src/main/kotlin/com/example/local_chat/MainActivity.kt) |
| Android wakelock | When the app is paused with active TCP peers, it enables wakelock until resume | [`lib/main.dart`](../lib/main.dart), [`android/app/src/main/AndroidManifest.xml`](../android/app/src/main/AndroidManifest.xml) |
| Android limitation | There is no dedicated Android foreground service yet, so long-running background reliability still depends on OS/vendor policy | [`android/app/src/main/AndroidManifest.xml`](../android/app/src/main/AndroidManifest.xml), [`lib/main.dart`](../lib/main.dart) |
| Windows tray/background | Closing the window can hide to tray when desktop background mode is enabled | [`lib/main.dart`](../lib/main.dart), [`lib/app_settings.dart`](../lib/app_settings.dart) |
| Windows attention | Incoming events can pulse taskbar progress and call native `FlashWindow` through FFI | [`lib/main.dart`](../lib/main.dart), [`lib/windows_taskbar_flash.dart`](../lib/windows_taskbar_flash.dart), [`lib/windows_taskbar_flash_io.dart`](../lib/windows_taskbar_flash_io.dart) |

## Reliability and Safety

| Area | Behavior | Code |
| --- | --- | --- |
| TCP frame limit | Incoming JSON lines larger than 1 MB are rejected by destroying the socket | [`lib/connection_service.dart`](../lib/connection_service.dart) |
| Dial dedupe | Concurrent dials to the same peer are guarded by a `_connecting` set | [`lib/connection_service.dart`](../lib/connection_service.dart) |
| Discovery cleanup | UDP subscriptions and multicast locks are cleaned up on rebind/stop/failure paths | [`lib/discovery_service.dart`](../lib/discovery_service.dart) |
| Transfer cleanup | Transfer manager disposes stream controllers, file-message subscriptions, and notification timer | [`lib/transfer_manager.dart`](../lib/transfer_manager.dart) |
| Attachment prep tests | Copy, cancel, missing source, temp-name sanitizing, and folder zip behavior are tested | [`test/attachment_prepare_test.dart`](../test/attachment_prepare_test.dart) |

## Verification

```bash
flutter test
flutter analyze
```

Current test files:

- [`test/attachment_prepare_test.dart`](../test/attachment_prepare_test.dart)
- [`test/chat_message_ordering_test.dart`](../test/chat_message_ordering_test.dart)
- [`test/staged_from_drop_test.dart`](../test/staged_from_drop_test.dart)
- [`test/storage_usage_test.dart`](../test/storage_usage_test.dart)
- [`test/folder_send_test.dart`](../test/folder_send_test.dart)
- [`test/client_platform_test.dart`](../test/client_platform_test.dart)
- [`test/file_transfer_auth_test.dart`](../test/file_transfer_auth_test.dart)

## QA improvement program

Step-by-step roadmap (Items 1–28), status, and agent resume instructions:

- [`docs/QA_IMPROVEMENTS_ROADMAP.md`](QA_IMPROVEMENTS_ROADMAP.md)
- [`docs/FILE_TRANSFER_PROTOCOL.md`](FILE_TRANSFER_PROTOCOL.md)
