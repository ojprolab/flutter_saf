import 'package:flutter/services.dart';
import 'package:flutter_saf/models/saf_directory.dart';
import 'package:flutter_saf/models/saf_file.dart';
import 'package:flutter_saf/models/saf_file_metadata.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';

import 'flutter_saf.dart' show SortBy;
import 'flutter_saf_method_channel.dart';

abstract class FlutterSafPlatform extends PlatformInterface {
  FlutterSafPlatform() : super(token: _token);

  static final Object _token = Object();
  static FlutterSafPlatform _instance = MethodChannelFlutterSaf();

  static FlutterSafPlatform get instance => _instance;

  static set instance(FlutterSafPlatform instance) {
    PlatformInterface.verifyToken(instance, _token);
    _instance = instance;
  }

  Future<SAFDirectory?> pickDirectory({String? initialUri}) {
    throw UnimplementedError('pickDirectory() is not implemented');
  }

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
    throw UnimplementedError('scanDirectory() is not implemented');
  }

  Future<Uint8List?> readFileBytes(
    String uri, {
    String? taskId,
    int? maxBytes,
  }) {
    throw UnimplementedError('readFileBytes() is not implemented');
  }

  /// Reads [size] bytes from [uri] starting at byte offset [position].
  /// Used to back [PdfDocument.openCustom] for SAF content URIs on Android.
  /// Returns null on error.
  Future<Uint8List?> readBytesAt(String uri, int position, int size) {
    throw UnimplementedError('readBytesAt() has not been implemented.');
  }

  Future<String?> copyFileToPath(
    String uri,
    String destPath, {
    String? taskId,
    bool overwrite = true,
    int bufferSize = 32768,
  }) {
    throw UnimplementedError('copyFileToPath() is not implemented');
  }

  Future<bool?> checkAccess(String uri) {
    throw UnimplementedError('checkAccess() is not implemented');
  }

  Future<bool?> deleteFile(String uri) {
    throw UnimplementedError('deleteFile() is not implemented');
  }

  Future<String?> renameFile(
    String uri, {
    String? newName,
    String? destPath,
  }) {
    throw UnimplementedError('renameFile() is not implemented');
  }

  Future<bool?> exists(String uri) {
    throw UnimplementedError('exists() is not implemented');
  }

  Future<SAFFileMetadata?> getFileMetadata(String uri) {
    throw UnimplementedError('getFileMetadata() is not implemented');
  }

  Future<bool?> releasePermission(String uri) {
    throw UnimplementedError('releasePermission() is not implemented');
  }
}
