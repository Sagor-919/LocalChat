# Alpha release checklist (1.7.0)

Use this before shipping APK / MSI / ZIP to testers.

## Version and identity

| Item | Location |
|------|----------|
| Semantic version + build | `pubspec.yaml` → `version: 1.7.0+7` (name + code) |
| In-app label | `lib/app_metadata.dart` → `AppMetadata.releaseLabel` |
| Publisher / developer | **Settings → About** reads `AppMetadata` + `package_info_plus` |
| Windows exe properties | `windows/runner/Runner.rc` (CompanyName, ProductName, LegalCopyright) |

After changing `pubspec.yaml`, run `flutter pub get` and rebuild so Android `versionName`/`versionCode` and Windows `FLUTTER_VERSION_*` pick up.

## Build commands

```bash
flutter pub get
flutter analyze
flutter test

# Android APK (debug or release)
flutter build apk --release

# Android App Bundle (Play)
flutter build appbundle --release

# Windows
flutter build windows --release
```

## Android signing (release)

- **Release** must use a **release keystore**, not debug. Current `android/app/build.gradle.kts` uses `signingConfigs.debug` for release — **replace before store** with `signingConfigs.release` and `key.properties` (do not commit secrets).
- **Play Console:** data safety form, permissions justification (MANAGE_EXTERNAL_STORAGE, etc.), privacy policy URL if required.
- **Application ID:** still `com.example.local_chat` — change to your final package name before production.

## Windows distribution

- Ship `build/windows/x64/runner/Release/` or use an installer (Inno Setup, MSIX, etc.).
- Code signing certificate (optional for alpha, recommended for wide distribution).

## Privacy and safety

- **LAN-only:** no central server; peers discover on the local network.
- **Data:** messages and attachments stored locally (SQLite + files); review `lib/message_store.dart` and download path settings.
- **Encryption:** chat payloads use the app’s crypto layer; treat keys as device-local.

## Optional

- [ ] `CHANGELOG.md` entry for this alpha
- [ ] Tag git: `git tag v1.7.0-alpha1`
- [ ] Crash/analytics (Firebase, Sentry) — not included by default
- [ ] Update screenshots on RecklessGalaxy.com

## What is *not* required for a private alpha

- Play Store listing (side-load APK is fine)
- Apple notarization (macOS/iOS if you add them later)
