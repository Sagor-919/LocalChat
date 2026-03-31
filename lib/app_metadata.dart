/// Release identity (keep in sync with [pubspec.yaml] version name when cutting a build).
class AppMetadata {
  AppMetadata._();

  /// Shown in Settings and docs (e.g. "Alpha 1.7.0").
  static const String releaseLabel = 'Alpha 1.7.0';

  static const String publisher = 'RecklessGalaxy.com';
  static const String developer = 'Sagor Hossen';

  /// Public site (no scheme in label).
  static const String publisherUrl = 'https://recklessgalaxy.com';

  static const String supportEmail = 'sagor@recklessgalaxy.com';
}
