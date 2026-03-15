import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_saf/models/saf_directory.dart';
import 'package:flutter_saf/models/saf_file.dart';
import 'package:flutter_saf/models/saf_file_metadata.dart';

import 'flutter_saf_platform_interface.dart';

class FlutterSaf {
  // ── Combined channel progress ─────────────────────────────────────────────
  //
  // Native pushes progress via methodChannel.invokeMethod("onProgress", …).
  // Call FlutterSaf.initialize() once in main() to wire up the handler.
  //
  // Usage:
  //   FlutterSaf.progress.listen((e) {
  //     if (e.taskId == myTaskId) print('${e.progress * 100}%');
  //   });

  static final _progressController = StreamController<ScanProgress>.broadcast();

  static Stream<ScanProgress> get progress => _progressController.stream;

  /// Wire up the native → Dart "onProgress" handler.
  /// Call once in main() before runApp():
  ///
  ///   void main() {
  ///     WidgetsFlutterBinding.ensureInitialized();
  ///     FlutterSaf.initialize();
  ///     runApp(MyApp());
  ///   }
  static void initialize() {
    const MethodChannel('flutter_saf').setMethodCallHandler((call) async {
      if (call.method == 'onProgress') {
        final map = Map<String, dynamic>.from(call.arguments as Map);
        _progressController.add(ScanProgress.fromMap(map));
      }
    });
  }

  // ── pickDirectory ─────────────────────────────────────────────────────────
  // [initialUri] Android only — pre-opens the picker at a specific location.
  // Returns null if the user cancels.
  // Errors: NO_ACTIVITY | ALREADY_ACTIVE | PERMISSION_ERROR | INVALID_URI | CANCELLED

  Future<SAFDirectory?> pickDirectory({String? initialUri}) {
    return FlutterSafPlatform.instance.pickDirectory(initialUri: initialUri);
  }

  // ── scanDirectory ─────────────────────────────────────────────────────────
  // [uri]            Tree URI from SAFDirectory (required).
  // [extensions]     e.g. ['epub','pdf']. Omit = all files.
  // [recursive]      Descend into sub-directories (default: true).
  // [taskId]         Echoed in progress events. Auto-generated if omitted.
  // [includeHidden]  Include dot-files (default: false).
  // [minSize]        Skip files smaller than N bytes.
  // [maxSize]        Skip files larger than N bytes.
  // [sortBy]         SortBy.name | .size | .lastModified
  // [sortDescending] Reverse sort order (default: false).
  // [limit]          Max results to return.
  // Errors: INVALID_ARGUMENTS | PERMISSION_DENIED | INVALID_URI | SCAN_ERROR

  Future<List<SAFFile>?> scanDirectory(
    String uri, {
    List<String>? extensions,
    bool recursive = true,
    String? taskId,
    bool includeHidden = false,
    int? minSize,
    int? maxSize,
    SortBy? sortBy,
    bool sortDescending = false,
    int? limit,
  }) {
    return FlutterSafPlatform.instance.scanDirectory(
      uri,
      extensions: extensions,
      recursive: recursive,
      taskId: taskId,
      includeHidden: includeHidden,
      minSize: minSize,
      maxSize: maxSize,
      sortBy: sortBy,
      sortDescending: sortDescending,
      limit: limit,
    );
  }

  // ── readFileBytes ─────────────────────────────────────────────────────────
  // ⚠️  Small files only (covers, thumbnails). Use copyFileToPath for books.
  // [maxBytes] Abort with FILE_TOO_LARGE if file exceeds this size.
  // Errors: INVALID_ARGUMENTS | NO_CONTEXT | READ_ERROR | OOM_ERROR |
  //         PERMISSION_ERROR | FILE_TOO_LARGE

  Future<Uint8List?> readFileBytes(
    String uri, {
    String? taskId,
    int? maxBytes,
  }) {
    return FlutterSafPlatform.instance.readFileBytes(
      uri,
      taskId: taskId,
      maxBytes: maxBytes,
    );
  }

  // ── readBytesAt ───────────────────────────────────────────────────────────
  // Range-read for PdfDocument.openCustom (Android scan flow only).
  // Returns bytes read — may be shorter than [size] at EOF.
  // Errors: INVALID_ARGUMENTS | NO_CONTEXT | READ_ERROR | PERMISSION_ERROR

  Future<Uint8List?> readBytesAt(String uri, int position, int size) {
    return FlutterSafPlatform.instance.readBytesAt(uri, position, size);
  }

  // ── copyFileToPath ────────────────────────────────────────────────────────
  // Streams uri → destPath in chunks. Never loads the full file into RAM.
  // [overwrite]  Replace dest if it exists (default: true).
  //              false → ALREADY_EXISTS error if dest exists.
  // [bufferSize] I/O buffer bytes (default: 32768, try 65536 for fast storage).
  // Returns destPath on success.
  // Errors: INVALID_ARGUMENTS | NO_CONTEXT | READ_ERROR | COPY_ERROR |
  //         OOM_ERROR | PERMISSION_ERROR | ALREADY_EXISTS

  Future<String?> copyFileToPath(
    String uri,
    String destPath, {
    String? taskId,
    bool overwrite = true,
    int bufferSize = 32768,
  }) {
    return FlutterSafPlatform.instance.copyFileToPath(
      uri,
      destPath,
      taskId: taskId,
      overwrite: overwrite,
      bufferSize: bufferSize,
    );
  }

  // ── checkAccess ───────────────────────────────────────────────────────────
  // Returns true if uri is readable right now. Never throws.

  Future<bool> checkAccess(String uri) async {
    return await FlutterSafPlatform.instance.checkAccess(uri) ?? false;
  }

  // ── deleteFile ────────────────────────────────────────────────────────────
  // Errors: INVALID_ARGUMENTS | INVALID_URI | UNSUPPORTED |
  //         PERMISSION_ERROR | DELETE_ERROR

  Future<bool> deleteFile(String uri) async {
    return await FlutterSafPlatform.instance.deleteFile(uri) ?? false;
  }

  // ── renameFile ────────────────────────────────────────────────────────────
  // [newName]  New display name in the same directory, e.g. "book.epub".
  // [destPath] iOS only — full destination path; takes priority over newName.
  // ⚠️  On Android the URI may change after rename. Use the returned URI.
  // Errors: INVALID_ARGUMENTS | INVALID_URI | UNSUPPORTED |
  //         PERMISSION_ERROR | RENAME_ERROR

  Future<String?> renameFile(
    String uri, {
    String? newName,
    String? destPath,
  }) {
    assert(
      newName != null || destPath != null,
      'Either newName or destPath must be provided',
    );
    return FlutterSafPlatform.instance.renameFile(
      uri,
      newName: newName,
      destPath: destPath,
    );
  }

  // ── exists ────────────────────────────────────────────────────────────────
  // Existence check only — does not verify readability. Never throws.

  Future<bool> exists(String uri) async {
    return await FlutterSafPlatform.instance.exists(uri) ?? false;
  }

  // ── getFileMetadata ───────────────────────────────────────────────────────
  // Single-file metadata without scanning the parent directory.
  // Returns null if the URI cannot be resolved.
  // Errors: INVALID_ARGUMENTS | INVALID_URI | METADATA_ERROR

  Future<SAFFileMetadata?> getFileMetadata(String uri) {
    return FlutterSafPlatform.instance.getFileMetadata(uri);
  }

  // ── releasePermission ─────────────────────────────────────────────────────
  // Revokes persisted permission / security-scoped bookmark for uri.
  // Subsequent calls for that uri will fail until the user picks again.

  Future<bool> releasePermission(String uri) async {
    return await FlutterSafPlatform.instance.releasePermission(uri) ?? false;
  }
}

// ── SortBy ────────────────────────────────────────────────────────────────────

enum SortBy {
  name('name'),
  size('size'),
  lastModified('lastModified');

  const SortBy(this.value);
  final String value;
}

// ── ScanProgress ──────────────────────────────────────────────────────────────

class ScanProgress {
  final String taskId;
  final double progress;
  final String status;

  const ScanProgress({
    required this.taskId,
    required this.progress,
    required this.status,
  });

  factory ScanProgress.fromMap(Map<String, dynamic> map) => ScanProgress(
        taskId: map['taskId'] as String? ?? '',
        progress: (map['progress'] as num?)?.toDouble() ?? 0.0,
        status: map['status'] as String? ?? '',
      );

  bool get isDone => status == 'done';
  bool get isIndeterminate => progress == 0.0 && !isDone;

  @override
  String toString() =>
      'ScanProgress($taskId ${(progress * 100).toStringAsFixed(0)}% $status)';
}
