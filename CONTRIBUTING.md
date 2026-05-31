# Contributing to LocalChat

Thanks for helping make LocalChat better. This project is an alpha LAN-first messenger, so small focused fixes are especially valuable.

## Development Setup

```bash
git clone https://github.com/Reckless2077/LocalChat.git
cd LocalChat
flutter pub get
flutter test
flutter analyze
```

Use Flutter stable and keep generated build output out of commits.

## Before Opening a PR

- Create a branch from `main`.
- Keep the PR focused on one bug, feature, or docs change.
- Run `flutter test` and `flutter analyze`.
- Update `README.md` or `docs/FEATURES.md` when user-visible behavior changes.
- Include screenshots or screen recordings for UI changes when practical.

## Code Guidelines

- Prefer existing app patterns over new abstractions.
- Keep LAN-only behavior explicit unless the change is intentionally about cross-network discovery.
- Avoid committing local build artifacts, generated caches, signing files, or machine-specific Flutter files.
- Keep Android release signing material private.

## Reporting Issues

Use the GitHub issue templates when possible. For security reports, do not open a public issue; follow `SECURITY.md`.
