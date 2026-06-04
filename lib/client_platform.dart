import 'package:flutter/foundation.dart';

/// Wire identifier for the local runtime (discovery + hello).
String get localClientPlatform {
  if (kIsWeb) return 'web';
  return switch (defaultTargetPlatform) {
    TargetPlatform.android => 'android',
    TargetPlatform.iOS => 'ios',
    TargetPlatform.windows => 'windows',
    TargetPlatform.linux => 'linux',
    TargetPlatform.macOS => 'macos',
    _ => 'unknown',
  };
}

/// Whether this peer can receive [folder direct] (multi-file layout, not a single .zip).
bool peerReceivesFolderAsFiles(String? platform) {
  if (platform == null || platform.isEmpty || platform == 'unknown') {
    return false;
  }
  return platform == 'windows' ||
      platform == 'linux' ||
      platform == 'macos';
}
