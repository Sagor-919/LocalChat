# DriveChat — Project Overview

## Summary

DriveChat is a **cross-platform local network (LAN) messaging and file transfer app**.
It works without internet by connecting devices on the same WiFi network.

The app is designed to feel like **Facebook Messenger**, but powered by **peer-to-peer communication**.

---

## Core Goals

* Simple and clean messaging UI (Messenger-style)
* Instant device discovery on local network
* Realtime messaging (no refresh, no delay)
* Fast file transfer between devices
* Lightweight and reliable
* Works across **iOS and Windows**

---

## Key Features

* 💬 Realtime chat
* 📁 File sharing (images, videos, documents)
* 👀 Online/offline presence
* 🔔 Local notifications
* 📡 Auto device discovery (no manual IP input)
* 📞 Press & hold “Ring” (attention ping)

---

## Tech Overview

### Frontend

* Flutter (single codebase for UI)

### Networking

* WebSocket (realtime communication)
* mDNS / Zeroconf (device discovery)

### Storage

* Local database (SQLite)

### Architecture

* Peer-to-peer (each device acts as both client and server)

---

# Development Phases

---

## Phase 1 — Device Discovery

### Goal

Detect and display devices on the same network.

### Tasks

* Implement mDNS service broadcasting
* Discover nearby devices
* Show list of available users

### Output

* "Nearby Devices" screen
* Devices appear/disappear in realtime

---

## Phase 2 — Connection System

### Goal

Establish connection between devices.

### Tasks

* Start WebSocket server on each device
* Connect to selected device
* Exchange user identity (name, ID)

### Output

* Tap device → connect
* Basic connection status (Connected / Disconnected)

---

## Phase 3 — Realtime Messaging

### Goal

Send and receive messages instantly.

### Tasks

* Design message format (JSON)
* Send text messages via WebSocket
* Receive and display messages
* Store messages locally

### Output

* Chat screen (Messenger-style)
* Messages update instantly

---

## Phase 4 — Notifications

### Goal

Notify users of new messages.

### Tasks

* Trigger local notification on message receive
* Handle app foreground/background states

### Output

* Notification appears for new messages
* Tap → opens chat

---

## Phase 5 — File Transfer

### Goal

Send files between devices.

### Tasks

* File picker integration
* Send file metadata (name, size)
* Transfer file in chunks
* Save file on receiver side

### Output

* Send/receive files in chat
* Progress indicator

---

## Phase 6 — Ring Feature

### Goal

Allow users to “ping” others.

### Tasks

* Detect press & hold gesture
* Send "ring" event
* Play sound/vibration on receiver

### Output

* Incoming ring alert UI
* Quick attention system

---

## Phase 7 — Sync System

### Goal

Keep messages consistent after reconnect.

### Tasks

* Assign unique IDs to messages
* Track last synced state
* Sync missing messages on reconnect

### Output

* Messages recover after disconnect
* No duplicates

---

## Phase 8 — UI Polish

### Goal

Make app feel smooth and modern.

### Tasks

* Clean Messenger-style UI
* Animations (message send, receive)
* Dark mode
* Profile avatars

### Output

* Production-ready interface

---

# Design Principles

* Keep UI minimal and familiar
* Prioritize speed over complexity
* Avoid unnecessary features early
* Build small → test → expand

---

# Future Ideas (Optional)

* Group chats
* Public file sharing
* Password-protected files
* Cross-network relay (internet fallback)

---

# First Milestone

👉 Successfully:

* Discover devices
* Connect
* Send 1 message

If this works, the foundation is complete.
