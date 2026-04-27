# Local Chat — feature reference (Alpha 1.7.0)

This document maps **user-visible behavior** to **code** so testers and contributors know what is implemented.

---

## Core principles

| Topic | Detail |
|--------|--------|
| Transport | **No cloud server** — discovery and chat are on the **LAN** (Wi‑Fi / Ethernet). |
| Discovery | **UDP** broadcast; peers appear on the home screen. |
| Chat | **TCP** JSON messages; one socket per peer session. |
| Files | **Separate TCP** file transfer with chunked I/O and progress. |
| Global Discovery | Optional paired text chat across networks with Nostr rendezvous, WebRTC data channels, and Noise. |

---

## Home screen

| Feature | Behavior | Code |
|---------|----------|------|
| Peer list | Shows discovered devices; refresh on discovery/connection events. | [`lib/home_screen.dart`](lib/home_screen.dart) |
| Online status | Connects TCP when opening chat; list reflects connection state. | [`lib/connection_service.dart`](lib/connection_service.dart), [`lib/discovery_service.dart`](lib/discovery_service.dart) |
| Identity merge | Same physical device after app data clear may **merge** chat history via LAN stable tag. | [`lib/services/device_identity_service.dart`](lib/services/device_identity_service.dart), [`lib/message_store.dart`](lib/message_store.dart) `mergePeerLanIdentity` |

---

## Chat screen

| Feature | Behavior | Code |
|---------|----------|------|
| Text messages | Multiline composer; Enter sends on desktop (hardware handler); encrypted when connected. | [`lib/chat_screen.dart`](lib/chat_screen.dart), [`lib/chat_crypto.dart`](lib/chat_crypto.dart) |
| Delivery states | Sent / confirming / delivered / undelivered (TCP). | [`lib/message_model.dart`](lib/message_model.dart), store |
| History | SQLite-backed; initial window + scroll-up pagination. | [`lib/message_store.dart`](lib/message_store.dart), [`lib/chat_screen.dart`](lib/chat_screen.dart) |
| Attachments | Stage files; **Send** sends all staged; optional caption text. | [`lib/chat_screen.dart`](lib/chat_screen.dart), [`lib/transfer_manager.dart`](lib/transfer_manager.dart) |
| Images in bubbles | Thumbnails; tap to open; **outbound** files copied to persistent storage so paths survive after send. | [`lib/transfer_manager.dart`](lib/transfer_manager.dart) |
| File transfer UI | Progress, pause/cancel, failed/cancelled styling. | [`lib/chat_screen.dart`](lib/chat_screen.dart), [`lib/transfer_manager.dart`](lib/transfer_manager.dart) |
| Copy message | Long-press / context menu; copy path or image bytes to clipboard. | [`lib/chat_screen.dart`](lib/chat_screen.dart) |
| Desktop | Drag-and-drop onto composer strip; **View in Explorer** when file missing opens configured download folder. | [`lib/chat_screen.dart`](lib/chat_screen.dart), [`lib/app_settings.dart`](lib/app_settings.dart) |
| Android | **Locate file** opens folder via Documents URI; **Share into app** queues staged items; **paste image** from clipboard (long-press composer). | [`MainActivity.kt`](../android/app/src/main/kotlin/com/example/local_chat/MainActivity.kt) |

---

## Global Discovery V5

| Feature | Behavior | Code |
|---------|----------|------|
| Pairing | 9-digit code plus SAS emoji verification; persists paired peers. | [`lib/pairing/pairing_screen.dart`](../lib/pairing/pairing_screen.dart), [`lib/global/pairing_service.dart`](../lib/global/pairing_service.dart) |
| Rendezvous | Public Nostr relays exchange encrypted WebRTC signaling. | [`lib/global/nostr_client.dart`](../lib/global/nostr_client.dart), [`lib/global/rendezvous_service.dart`](../lib/global/rendezvous_service.dart) |
| Transport | WebRTC data channel with Noise overlay; LAN remains preferred. | [`lib/global/webrtc_session.dart`](../lib/global/webrtc_session.dart), [`lib/global/noise_session.dart`](../lib/global/noise_session.dart), [`lib/global/global_discovery_v2.dart`](../lib/global/global_discovery_v2.dart) |
| Text messages | Uses the same `MessageStore` and ACK flow as LAN. LAN TCP keeps `ChatCrypto`; global text rides inside Noise. | [`lib/main.dart`](../lib/main.dart), [`lib/chat_screen.dart`](../lib/chat_screen.dart), [`lib/message_store.dart`](../lib/message_store.dart) |
| Files | Global-only peers cannot send files until `TransferManager` has a data-channel adapter. | [`lib/chat_screen.dart`](../lib/chat_screen.dart), [`lib/transfer_manager.dart`](../lib/transfer_manager.dart) |
| Limit | No TURN server; some NAT combinations fail. | [`GLOBAL_DISCOVERY_SPEC.md`](../GLOBAL_DISCOVERY_SPEC.md) |

---

## Attachments pipeline

| Stage | Detail |
|----------|--------|
| Pick | Desktop: `file_picker`, folder → zip at send. Android: native SAF (`content://`) without copy-at-pick for attach; gallery/image picker as paths. |
| Prepare | Content URIs materialized to temp; duplicate paths in one batch copied; folder zipped. | [`lib/transfer_manager.dart`](lib/transfer_manager.dart), [`lib/attachment_prepare.dart`](lib/attachment_prepare.dart) |
| Persist outbound | Temp send paths are copied to **`getApplicationDocumentsDirectory()/outbound_attachments/`** before DB update so cleanup after send does not delete the preview file. | [`lib/transfer_manager.dart`](lib/transfer_manager.dart) |
| Transfer | Chunked send/receive; resume paths on receiver. | [`lib/file_transfer_service.dart`](lib/file_transfer_service.dart) |

---

## Settings

| Feature | Code |
|---------|------|
| Theme | System / light / dark — [`lib/app_settings.dart`](lib/app_settings.dart) |
| Download folder | Default + picker; Android storage probes — [`lib/settings_screen.dart`](lib/settings_screen.dart), [`lib/android_storage_access.dart`](lib/android_storage_access.dart) |
| Android battery | Unrestricted battery hint — [`lib/android_app_control.dart`](lib/android_app_control.dart) |
| Desktop | Run in background, start with Windows (where applicable) — [`lib/app_settings.dart`](lib/app_settings.dart) |
| About | Version (`package_info_plus`), publisher, developer — [`lib/app_metadata.dart`](lib/app_metadata.dart), [`lib/settings_screen.dart`](lib/settings_screen.dart) |

---

## Notifications & tray

| Platform | Behavior |
|----------|----------|
| Android | Local notifications plugin; channels configured in [`lib/main.dart`](lib/main.dart) |
| Windows | Tray icon, minimize to tray, optional close-to-tray — [`lib/main.dart`](lib/main.dart) |

---

## First launch

| Flow | Code |
|------|------|
| Notifications, storage, download folder | [`lib/first_launch_prompt.dart`](lib/first_launch_prompt.dart) |

---

## Tests

| Area | File |
|------|------|
| Attachment prepare helpers | [`test/attachment_prepare_test.dart`](../test/attachment_prepare_test.dart) |
| Global Discovery contracts | [`test/global/global_discovery_v2_test.dart`](../test/global/global_discovery_v2_test.dart) |

Run: `flutter test`

---

## Snackbars

Centralized top placement (below app bar): [`lib/app_snackbar.dart`](../lib/app_snackbar.dart)
