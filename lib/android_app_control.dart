import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

const _kAppControlChannel = MethodChannel('local_chat/app_control');

/// Sends the app to the recents drawer without killing the process (Android only).
Future<void> moveAndroidTaskToBackground() async {
  if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) return;
  try {
    await _kAppControlChannel.invokeMethod<void>('moveTaskToBack');
  } catch (_) {}
}

/// Whether this app is exempt from Android battery optimization (API 23+). True on non-Android.
Future<bool> androidIgnoringBatteryOptimizations() async {
  if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) return true;
  try {
    final v = await _kAppControlChannel
        .invokeMethod<bool>('isIgnoringBatteryOptimizations');
    return v ?? true;
  } catch (_) {
    return true;
  }
}

/// Opens the system dialog to allow ignoring battery optimizations for this app.
Future<void> androidRequestIgnoreBatteryOptimizations() async {
  if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) return;
  try {
    await _kAppControlChannel
        .invokeMethod<void>('requestIgnoreBatteryOptimizations');
  } catch (_) {}
}

/// App info screen (user can change battery / background restrictions manually).
Future<void> androidOpenApplicationDetailsSettings() async {
  if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) return;
  try {
    await _kAppControlChannel
        .invokeMethod<void>('openApplicationDetailsSettings');
  } catch (_) {}
}
