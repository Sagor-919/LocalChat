# Global Discovery V5 Spec

Status: V5 integration contract for `Dev-LocalChatV5-GlobalDiscovery`.
Base branch: `origin/Dev-LocalChatV4`.
Stable branch rule: `Dev-LocalChatV4` stays untouched. All work lands only on
`Dev-LocalChatV5-GlobalDiscovery`.

## Why This Revision Exists

The original Global Discovery spec was drafted from `main`, but the stable app is
`Dev-LocalChatV4`. V4 already contains the current LocalChat systems for SQLite
message history, LAN identity merging, TCP chat delivery, notifications, tray /
background behavior, file staging, and transfer management. Global Discovery must
integrate with those systems instead of replacing or bypassing them.

## Non-Negotiable V4 Contracts

1. `MessageStore` is the only persisted chat-history system.
   - All received and sent chat messages must be stored through `MessageStore.add`.
   - Delivery state must continue to use `MessageDelivery` and
     `MessageStore.updateDeliveryState`.
   - Pending / interrupted outgoing text must continue to use
     `loadOutboundTextNeedingSync` and `markPendingOutgoingAsUndelivered`.
   - UI refresh must continue to flow through `messageHistoryRevision`.

2. V4's application message envelope stays authoritative.
- Global transport sends the same JSON message types as LAN TCP:
  `message`, `message_ack`, `message_ack_confirm`, `file_notify`,
  `file_control`, `ping`, and `pong`.
- Global Discovery may add transport metadata internally, but stored chat
  rows and UI code must not need a second message model.
- V4 `ChatCrypto` is LAN-TCP-only because it derives keys from LAN peer IDs.
  Global text rides inside the Noise-encrypted WebRTC channel as the normal
  `message` JSON envelope.

3. LAN remains first choice.
   - `DiscoveryService` and `ConnectionService` keep the current LAN behavior.
   - When LAN TCP is connected for a peer, chat uses LAN.
   - Global WebRTC is a fallback for paired peers that are not reachable on LAN.

4. File transfer is not considered globally supported until it has a transport
   adapter.
   - V4 `TransferManager` currently depends on TCP sockets and peer IPs.
   - A global data-channel file path must either adapt `TransferManager` behind
     an explicit transport interface or keep global peers text-only with file
     actions disabled until the adapter exists.
   - Do not fake file delivery by writing metadata rows without moving bytes.

5. Peer identity must stay stable and unambiguous.
   - LAN peers keep V4 `DeviceInfo.userId` UUIDs and optional `lanStableTag`.
   - Paired global peers use their long-term Ed25519 public key as the stable
     identity. UI adapters may prefix it, but must not merge it with a LAN UUID
     unless there is cryptographic or stored user-confirmed evidence.
   - If the same device appears once via LAN and once via Global Discovery,
     duplicate entries are safer than corrupt history. Identity-linking can be a
     later, explicit migration.

6. Existing UX stays intact.
   - Home chat list still hydrates previews from `MessageStore`.
   - Chat screen still pages history from `MessageStore`.
   - Notifications still use the current app notification pipeline.
   - Existing Android / desktop background behavior remains untouched unless a
     Global Discovery phase explicitly needs an additive hook.

## Current Global Discovery Architecture

Implemented phases on V5:

- Phase 0: dependencies and platform WebRTC registrants.
- Phase 1: persisted Ed25519 / X25519 local identity.
- Phase 2: multi-relay Nostr client, event signing, and encrypted payloads.
- Phase 3: pairing service, SAS verification, paired-peer persistence, pairing UI.
- Phase 4: Nostr rendezvous messages for WebRTC signaling.
- Phase 5: WebRTC session wrapper and STUN configuration.
- Phase 6: Noise-style identity-pinned overlay over WebRTC data-channel frames.

Remaining V5 phases must be adapted to V4:

## Phase 7 - V4 Orchestrator And Chat Integration

Goal: add Global Discovery as an optional paired-peer transport while preserving
V4's LAN-first chat system.

Required shape:

- Add `lib/global/global_discovery_v2.dart`.
- Load `LocalIdentity`, `GlobalPeerStore`, configured relays, `NostrClient`, and
  `RendezvousService`.
- Expose paired peers and reachability as a listenable/stream that Home can merge
  with LAN peers without changing how message previews are loaded.
- Expose a JSON send path compatible with V4 message envelopes.
- Prefer `ConnectionService.sendJson` when LAN is connected.
- Use WebRTC + Noise only when LAN is unavailable and the peer is paired.
- Route received global JSON frames through the same handlers that LAN messages
  use in `main.dart`, so ACKs, delivery confirmation, notifications, and
  `MessageStore` updates stay identical.
- Settings must show local global identity, pairing entry point, paired peers,
  and relay status.
- File UI must remain disabled or clearly unavailable for global-only peers until
  the transfer adapter is implemented.

Fast tests:

- Unit-test peer merge ordering: LAN online peer wins over global paired peer.
- Unit-test global JSON inbound path stores through `MessageStore.add`.
- Unit-test LAN-preferred send path chooses `ConnectionService` before global.
- `flutter test test/global`.
- `flutter analyze`.
- `flutter build apk --debug`.

Manual QA:

- V4 LAN chat still works with no internet.
- A paired global peer appears without LAN discovery.
- Text sent over global persists in the same chat history.
- Reopen app: global peers and message history remain.

## Phase 8 - Cleanup And Documentation

Goal: remove only code that is truly obsolete in V5 and document the user-facing
behavior.

Rules:

- Do not delete or alter V4 LAN discovery, V4 TCP chat, or V4 transfer code.
- Remove old Global Discovery code only if it exists on the V5 branch and is no
  longer referenced.
- Update `README.md` and `docs/FEATURES.md` with the real V5 behavior:
  LAN-first, pairing-based global text chat, no TURN, public-relay rendezvous,
  and any file-transfer limitations.
- Keep acceptance honest: without TURN, some NAT combinations fail.

Final verification:

- `rg "HttpRelayDiscoveryClient|global_discovery.dart"` should find no stale
  old global relay implementation references, if such code exists.
- `flutter test`.
- `flutter analyze`.
- `flutter build apk --debug`.

## Branch And Commit Guardrails

- Never switch to or commit on `Dev-LocalChatV4` for this work.
- Keep commits phase-scoped.
- Do not stage local reference folders such as `.claude/`, `_ref_lanmessenger/`,
  `_ref_p2p/`, or `_ref_peer_zip_extract/`.
- Generated plugin registrant line-ending/stat noise is not part of a phase
  unless there is a real content diff.
