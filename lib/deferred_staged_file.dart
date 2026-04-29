/// How the attachment was chosen (for send-time preparation only).
enum StagedSourceKind {
  /// Regular file path (picker, drop, gallery, share).
  file,
  /// Desktop folder: archive is built at send time into a temp .zip.
  folderToZip,
}

/// Composer-only lifecycle (optional; entries are cleared on Send).
enum StagingStatus {
  virtual,
  preparing,
  sending,
  sent,
  failed,
  cancelled,
}

/// Lightweight staging row: avoid heavy I/O until Send (Android `content://`
/// shares keep only [androidContentUri] until preparation).
class DeferredStagedFile {
  /// Local path when known (picker, `file://` share, gallery, drop, folder).
  final String? sourcePath;
  /// Android `content://` URI — copied to a temp file during Preparing.
  final String? androidContentUri;
  final String displayName;
  final StagedSourceKind kind;
  /// From [PlatformFile.size] when the picker supplies it; otherwise null.
  final int? knownSizeBytes;
  /// SHA-256 hex of pasted image bytes — duplicate pastes into staging are skipped.
  final String? clipboardPasteHash;

  DeferredStagedFile({
    this.sourcePath,
    this.androidContentUri,
    required this.displayName,
    this.kind = StagedSourceKind.file,
    this.knownSizeBytes,
    this.clipboardPasteHash,
  }) {
    if (kind == StagedSourceKind.folderToZip) {
      assert(sourcePath != null && sourcePath!.isNotEmpty);
      assert(androidContentUri == null);
    } else {
      final p = sourcePath != null && sourcePath!.isNotEmpty;
      final u = androidContentUri != null && androidContentUri!.isNotEmpty;
      assert(p || u);
    }
  }

  /// Stable key for duplicate detection within one Send batch.
  String get stagingDedupeKey => androidContentUri ?? sourcePath ?? '';

  /// Path for thumbnails / context menu when already on disk.
  String? get localPathForPreview {
    if (kind == StagedSourceKind.folderToZip) return null;
    if (sourcePath != null && sourcePath!.isNotEmpty) return sourcePath;
    return null;
  }
}
