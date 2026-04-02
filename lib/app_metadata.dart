/// Release identity (keep in sync with [pubspec.yaml] version name when cutting a build).
class AppMetadata {
  AppMetadata._();

  /// Short release channel label (version number comes from package_info).
  static const String releaseLabel = 'Alpha';

  static const String publisher = 'RecklessGalaxy.com';
  static const String developer = 'Sagor Hossen';

  /// Public site (no scheme in label).
  static const String publisherUrl = 'https://recklessgalaxy.com';

  static const String supportEmail = 'sagor@recklessgalaxy.com';
}
