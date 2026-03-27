GOAL:
Build a simple, fast, peer-to-peer LAN messaging app using Flutter that automatically discovers nearby devices, allows one-tap chat, and supports file/image sharing with a Messenger-style UI.

CORE PRINCIPLES:

No server (pure LAN / P2P)
Fast and lightweight
Stable file transfer (chunked streaming)
Clean, modern UI (Messenger-like)
Cross-platform (Android + Desktop)
PHASE 1 — PROJECT SETUP
Create Flutter project
Enable desktop support (Windows)
Setup folder structure:
/core (networking, models)
/features (chat, discovery, transfer)
/ui (screens, widgets)
Add dependencies:
provider / riverpod (state)
file_picker
desktop_drop (desktop only)
Setup basic navigation

OUTPUT:

App launches with empty home screen
PHASE 2 — DEVICE DISCOVERY (UDP)

GOAL: Automatically detect nearby devices on LAN

IMPLEMENT:

Use UDP broadcast (e.g., port 45454)
Send DISCOVER message every few seconds:
{ "type": "DISCOVER", "name": deviceName }
Listen for incoming DISCOVER messages
Respond with:
{ "type": "RESPONSE", "name": deviceName, "ip": localIP }
Maintain in-memory list of active devices
Remove inactive devices after timeout

UI:

Home screen shows list of nearby devices
Auto-refresh list

OUTPUT:

Devices appear/disappear in real-time
PHASE 3 — CONNECTION + CHAT (TCP)

GOAL: Tap device → start chat session

IMPLEMENT:

On tap → create TCP connection (fixed port)
Exchange handshake:
{ "type": "HELLO", "name": deviceName }
Maintain persistent socket per peer
Send/receive messages as JSON:
{ "type": "MESSAGE", "text": "...", "timestamp": ... }

UI:

Messenger-style chat screen
Message bubbles (left/right)
Input field + send button

OUTPUT:

Real-time messaging between devices
PHASE 4 — FILE TRANSFER (CORE FEATURE)

GOAL: Send files reliably (like LAN Messenger)

IMPLEMENT:

Separate TCP channel OR reuse connection
Handshake before transfer:
{ "type": "FILE_META", "name": "...", "size": ... }
Receiver replies: "START"

SENDING LOGIC:

Read file in 64KB chunks
Send chunk
WAIT for socket flush before next
Repeat until done

RECEIVING LOGIC:

Continuously read bytes
Append to file
Track progress

FAILSAFE:

Timeout if no progress (10–15 sec)
Cancel and clean partial file

OUTPUT:

Stable large file transfer (no freezing)
PHASE 5 — IMAGE PREVIEW

GOAL: Show images inside chat

IMPLEMENT:

Detect file type (image vs other)
If image:
Show thumbnail in chat bubble
Tap to open full-screen preview
Cache received images locally

UI:

Messenger-style image bubble
Fullscreen viewer

OUTPUT:

Smooth image preview experience
PHASE 6 — DRAG & DROP + PICKER

GOAL: Easy file sending

DESKTOP:

Drag & drop files into chat (desktop_drop)

ANDROID:

File picker button

COMMON:

Show selected file preview before sending

OUTPUT:

Simple and intuitive file sharing
PHASE 7 — STABILITY & PERFORMANCE

IMPLEMENT:

Chunk-based transfer (64KB)
Backpressure handling (await socket flush)
Prevent UI blocking (async / isolate if needed)
Connection retry logic
Proper error handling

OUTPUT:

No freeze, no crash on large files
PHASE 8 — POLISH
Show online/offline status
Progress bar for file transfer
Typing indicator (optional)
Dark/light theme
Device rename

OUTPUT:

Production-like experience
FUTURE UPGRADES (OPTIONAL)
Resume interrupted transfer
Multi-device group chat
Encryption (AES)
QR code connection fallback
WebRTC upgrade
FINAL RESULT:

A clean, stable LAN messenger with:

Auto device discovery
1-tap chat
Messenger UI
Reliable file transfer
Image preview