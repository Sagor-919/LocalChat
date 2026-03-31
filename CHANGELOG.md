# Changelog

## Alpha 1.7.0 (2026-03-31)

**Publisher:** RecklessGalaxy.com · **Developer:** Sagor Hossen

### Highlights

- **Networking:** UDP broadcast discovery, TCP chat (JSON), separate TCP file transfer with chunked streaming, pause/resume, delivery states.
- **Security:** End-to-end encryption for chat messages ([`lib/chat_crypto.dart`](lib/chat_crypto.dart)).
- **Attachments:** Outbound copies persisted under app documents so sent thumbnails stay valid after transfer; Android share/SAF deferred until send; folder zip on send.
- **Platforms:** Android (notifications, battery hint, share-in, native folder picker, clipboard image copy via `FileProvider`), Windows (tray, background, autostart), Linux/macOS where enabled.
- **UX:** Composer paste image, snackbars below app bar, theme modes, settings About shows version from `package_info_plus`.

### Notes

- Alpha builds are for testing; expect rough edges. Report issues via the contact on the Settings screen.

---

## Earlier

- Prior releases were not tracked in this file; see git history.
