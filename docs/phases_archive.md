# Archived implementation phases (historical)

This was the original step-by-step build plan. It is **not** the current user-facing documentation — see [`README.md`](../README.md) and [`FEATURES.md`](FEATURES.md).

---

GOAL:
Build a simple, fast, peer-to-peer LAN messaging app using Flutter that automatically discovers nearby devices, allows one-tap chat, and supports file/image sharing with a Messenger-style UI.

CORE PRINCIPLES:

No server (pure LAN / P2P)
Fast and lightweight
Stable file transfer (chunked streaming)
Clean, modern UI (Messenger-like)
Cross-platform (Android + Desktop)

PHASE 1 — PROJECT SETUP  
Create Flutter project; enable desktop; folder structure; dependencies.

PHASE 2 — DEVICE DISCOVERY (UDP)  
UDP broadcast; DISCOVER / RESPONSE; in-memory peer list; timeouts.

PHASE 3 — CONNECTION + CHAT (TCP)  
Tap device → TCP; HELLO handshake; JSON messages; bubbles.

PHASE 4 — FILE TRANSFER  
Separate channel; chunked send; progress; timeout / cancel.

PHASE 5 — IMAGE PREVIEW  
Thumbnails in bubbles; tap to open.

PHASE 6 — DRAG & DROP + PICKER  
Desktop drop; Android picker; staged preview.

PHASE 7 — STABILITY & PERFORMANCE  
Chunking; backpressure; retries; errors.

PHASE 8 — POLISH  
Status; progress; theme; device rename.

FUTURE (OPTIONAL)  
Resume transfer; multi-device group; encryption (superseded by current crypto); QR; WebRTC.

---

## Manual QA (deferred attachments & Android share)

**Deferred send:** Stage files or folder; zip only at send; duplicate paths → **Preparing…** then **Sending…**; cancel cleans temps.

**Large file:** Multi-GB send; UI stays responsive.

**Android share:** Share from another app → Local Chat; home banner; open chat → staged; Send → **Preparing…** then transfer.

**Cold start:** `syncFromNative` in [`lib/main.dart`](../lib/main.dart) so intents are not lost.
