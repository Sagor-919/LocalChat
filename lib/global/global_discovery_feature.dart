/// Single source of truth for whether Global Discovery is active in this
/// build. Gating goes through [GlobalDiscoveryFeature.isAvailable] so call
/// sites never hard-code the decision and the feature can be turned off
/// without touching transport, UI, or LAN code.
///
/// Layers:
///
///  - [isCompiledIn]: compile-time `--dart-define=GLOBAL_DISCOVERY=...`.
///    When `false`, AOT tree-shaking removes the dead Global Discovery
///    branches in `main.dart` and the settings UI. Useful for stripped-down
///    cross-platform builds (web, iOS App Store, locked-down enterprise
///    builds) where shipping the Nostr / WebRTC stack is undesirable.
///
///  - [isAvailable]: runtime gate. Today it equals [isCompiledIn]. When the
///    Pro entitlement system lands it will additionally consult the user's
///    purchase / subscription state. UI and bootstrap call this getter, so
///    that future change is local to this file.
///
/// LAN discovery and TCP chat (V4 contracts) are independent of this gate
/// and must keep working when Global Discovery is disabled.
library;

class GlobalDiscoveryFeature {
  GlobalDiscoveryFeature._();

  /// Compile-time switch. Default `true` keeps existing behavior; set to
  /// `false` for a build to strip Global Discovery entirely:
  ///
  /// ```
  /// flutter build apk --dart-define=GLOBAL_DISCOVERY=false
  /// ```
  ///
  /// Flip the [defaultValue] to `false` to make Global Discovery opt-in
  /// for every build by default (e.g. once it ships as a Pro feature).
  static const bool isCompiledIn = bool.fromEnvironment(
    'GLOBAL_DISCOVERY',
    defaultValue: true,
  );

  /// True when Global Discovery should be wired into the running app.
  /// Combines [isCompiledIn] with the runtime entitlement gate.
  ///
  /// Call sites (bootstrap, settings, peer merge) should branch on this
  /// getter rather than checking [isCompiledIn] directly so the Pro
  /// entitlement hook below is the only place that ever changes.
  static bool get isAvailable => isCompiledIn && _runtimeUnlocked;

  /// Runtime entitlement flag. Reserved for the upcoming Pro feature
  /// integration (StoreKit / Play Billing / license server). Defaults to
  /// `true` so today's builds behave as before once [isCompiledIn] is on.
  ///
  /// When Pro lands, replace the default with `false` and have the
  /// entitlement layer call [setRuntimeUnlocked] after a successful
  /// purchase / restore.
  static bool _runtimeUnlocked = true;

  /// Hook for the future Pro entitlement system. Idempotent. Safe to call
  /// from any isolate after [setRuntimeUnlocked] is wired into the
  /// purchase flow; UI rebuild is the caller's responsibility.
  static void setRuntimeUnlocked(bool unlocked) {
    _runtimeUnlocked = unlocked;
  }
}
