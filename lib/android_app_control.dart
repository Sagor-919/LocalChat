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
