# Changelog

## 1.8.2 (2026-06-06)

### Discovery (LAN) — robust multi-homed adapter handling + active discovery

- **NetworkAdapterService**: new module that enumerates and classifies every IPv4
  adapter as usable / virtual / loopback / link-local / non-private. Hyper‑V
  "Default Switch", WSL, Docker, VPN, VMware, VirtualBox host-only, Tailscale, and
  ZeroTier are excluded **by name** even when their IP looks private (e.g. the
  Hyper‑V Default Switch on `172.x`), so discovery only advertises on the real LAN.
- **Subnet broadcast & multicast** now flow only through selected real LAN adapters.
- **Manual adapter override**: Settings → Network lists each adapter with its IP and
  used/ignored reason, and lets you pick a preferred adapter when auto-detection
  chooses the wrong NIC. Changing it rebinds discovery immediately.
- **Active unicast sweep**: when no peers are found ~5s after launch, Local Chat
  walks every host on each real subnet with throttled directed beacons (~20/s) —
  needed when a router blocks wired→Wi‑Fi broadcast (AP isolation).
- **Startup unicast to known peers**: stored peer IPs are beaconed on launch so an
  online-but-broadcast-unreachable peer appears without first sending a message.
- **Add by IP**: empty-state offers a manual connect when auto-discovery is exhausted.
- **Phased empty state**: searching → scanning your network → "Add by IP" + tips.

---

## 1.8.1 (2026-06-06)

### Discovery (LAN)

- **Directed unicast beacons** to known peer IPs when broadcast is blocked (common with Ethernet PC + Wi‑Fi phone)
- **TCP peer learning**: register peers from active chat/file TCP sessions so the home list stays in sync without UDP
- **LAN-only broadcast**: skip Hyper‑V / WSL / Docker virtual NICs when choosing subnet broadcast targets
- **Startup**: await subnet broadcast targets before the first discovery beacon
- **Android**: `NEARBY_WIFI_DEVICES` manifest permission for LAN multicast on Android 13+
- **UI hint** when virtual and physical LAN adapters are both present

---

## 1.8.0 (2026-04-30)

**Publisher:** RecklessGalaxy.com · **Developer:** Sagor Hossen

### Changes

- **Startup**: splash screen paints immediately on launch; heavy init (SQLite, sockets, notifications) runs behind it so the app feels instant
- **Boot performance**: `DeviceInfo` and `MessageStore` init now run in parallel — faster cold start
- **File transfer UX**: attempting to send files without a LAN connection now shows "File transfer needs a LAN connection" instead of silently ignoring the action; drop target disabled when no active connection
- **Web compatibility**: `kIsWeb` guards added throughout so the binary compiles and runs on web targets without crashes (LAN and SQLite features remain desktop/mobile only)
- **Taskbar flash (Windows)**: refactored to a conditional export (`_io` / `_stub`) — no runtime `kIsWeb` check on every call
- **Global Discovery removed**: experimental Nostr/WebRTC cross-network pairing feature removed entirely; codebase reverted to stable LAN-only foundation
- **Resource leaks fixed**: UDP datagram subscription now stored and cancelled on rebind/stop; `TransferManager` stream controllers and notification timer properly disposed; `fileMessages` subscription cancelled on app widget dispose
- **Connection reliability**: `connectTo()` now guards against two concurrent dials to the same peer racing and leaving a zombie socket
- **Security**: 1 MB line-length limit on incoming TCP JSON frames — socket destroyed immediately if a peer sends an unbounded frame
- **Android multicast lock**: released correctly if UDP socket bind fails during `start()`

### Notes

- Alpha builds are for testing. Report issues via the contact on the Settings screen.

---

## 1.7.0 (2026-03-31)

### Highlights

- UDP broadcast discovery, TCP chat (JSON), separate TCP file transfer with chunked streaming, pause/resume, delivery states
- End-to-end encryption for chat messages
- Outbound attachment copies persisted under app documents; Android share/SAF deferred until send; folder zip on send
- Android: notifications, battery hint, share-in, native folder picker, clipboard image copy via `FileProvider`
- Windows: system tray, background mode, autostart, taskbar attention
- Composer paste image, snackbars below app bar, theme modes

---

## Earlier

Prior releases not tracked here — see git history.
