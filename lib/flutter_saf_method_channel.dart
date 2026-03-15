import 'package:flutter/services.dart';
import 'package:flutter_saf/models/saf_directory.dart';
import 'package:flutter_saf/models/saf_file.dart';
import 'package:flutter_saf/models/saf_file_metadata.dart';

import 'flutter_saf.dart' show SortBy;
import 'flutter_saf_platform_interface.dart';

class MethodChannelFlutterSaf extends FlutterSafPlatform {
  final methodChannel = const MethodChannel('flutter_saf');

  @override
  Future<SAFDirectory?> pickDirectory({String? initialUri}) async {
    final result = await methodChannel.invokeMapMethod<String, dynamic>(
      'pickDirectory',
      {if (initialUri != null) 'initialUri': initialUri},
    );
    if (result == null) return null;
    return SAFDirectory.fromMap(result);
  }

  @override
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
  }) async {
    final result = await methodChannel.invokeListMethod<Map>('scanDirectory', {
      'uri': uri,
      'recursive': recursive,
      'includeHidden': includeHidden,
      'sortDescending': sortDescending,
      if (extensions != null && extensions.isNotEmpty) 'extensions': extensions,
      if (taskId != null) 'taskId': taskId,
      if (minSize != null) 'minSize': minSize,
      if (maxSize != null) 'maxSize': maxSize,
      if (sortBy != null) 'sortBy': sortBy.value,
      if (limit != null) 'limit': limit,
    });
    if (result == null) return null;
    return result
        .map((e) => SAFFile.fromMap(Map<String, dynamic>.from(e)))
        .toList();
  }

  @override
  Future<Uint8List?> readFileBytes(
    String uri, {
    String? taskId,
    int? maxBytes,
  }) {
    return methodChannel.invokeMethod<Uint8List>('readFileBytes', {
      'uri': uri,
      if (taskId != null) 'taskId': taskId,
      if (maxBytes != null) 'maxBytes': maxBytes,
    });
  }

  @override
  Future<Uint8List?> readBytesAt(String uri, int position, int size) {
    return methodChannel.invokeMethod<Uint8List>('readBytesAt', {
      'uri': uri,
      'position': position,
      'size': size,
    });
  }

  @override
  Future<String?> copyFileToPath(
    String uri,
    String destPath, {
    String? taskId,
    bool overwrite = true,
    int bufferSize = 32768,
  }) {
    return methodChannel.invokeMethod<String>('copyFileToPath', {
      'uri': uri,
      'destPath': destPath,
      'overwrite': overwrite,
      'bufferSize': bufferSize,
      if (taskId != null) 'taskId': taskId,
    });
  }

  @override
  Future<bool?> checkAccess(String uri) {
    return methodChannel.invokeMethod<bool>('checkAccess', {'uri': uri});
  }

  @override
  Future<bool?> deleteFile(String uri) {
    return methodChannel.invokeMethod<bool>('deleteFile', {'uri': uri});
  }

  @override
  Future<String?> renameFile(
    String uri, {
    String? newName,
    String? destPath,
  }) {
    return methodChannel.invokeMethod<String>('renameFile', {
      'uri': uri,
      if (newName != null) 'newName': newName,
      if (destPath != null) 'destPath': destPath,
    });
  }

  @override
  Future<bool?> exists(String uri) {
    return methodChannel.invokeMethod<bool>('exists', {'uri': uri});
  }

  @override
  Future<SAFFileMetadata?> getFileMetadata(String uri) async {
    final result = await methodChannel.invokeMapMethod<String, dynamic>(
      'getFileMetadata',
      {'uri': uri},
    );
    if (result == null) return null;
    return SAFFileMetadata.fromMap(result);
  }

  @override
  Future<bool?> releasePermission(String uri) {
    return methodChannel.invokeMethod<bool>('releasePermission', {'uri': uri});
  }
}
