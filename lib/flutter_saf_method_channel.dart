import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_saf/exceptions/saf_exception.dart';
import 'package:flutter_saf/models/saf_directory.dart';
import 'package:flutter_saf/models/saf_file.dart';

import 'flutter_saf_platform_interface.dart';

/// An implementation of [FlutterSafPlatform] that uses method channels.
class MethodChannelFlutterSaf extends FlutterSafPlatform {
  /// The method channel used to interact with the native platform.
  @visibleForTesting
  final methodChannel = const MethodChannel('flutter_saf');

  @override
  Future<SAFDirectory?> pickDirectory() async {
    try {
      final pickedDirectory = await methodChannel
          .invokeMethod<Map<Object?, Object?>?>('pickDirectory');

      if (pickedDirectory == null) return null;

      final directory = Map<String, dynamic>.from(pickedDirectory);

      return SAFDirectory.fromMap(directory);
    } on PlatformException catch (exception) {
      throw SAFException(
        code: exception.code,
        message: exception.message ?? 'Unknown error',
        details: exception.details,
      );
    }
  }

  @override
  Future<List<SAFFile>?> scanDirectory(
    String uri, {
    List<String>? extensions,
    bool recursive = true,
  }) async {
    try {
      final detectedFiles = await methodChannel.invokeMethod<List<Object?>?>(
        'scanDirectory',
        <String, dynamic>{
          'uri': uri,
          'extensions': extensions,
          'recursive': recursive,
        },
      );

      if (detectedFiles == null) return null;

      final files = detectedFiles
          .map((file) => SAFFile.fromMap(
              Map<String, dynamic>.from(file as Map<Object?, Object?>)))
          .toList();

      return files;
    } on PlatformException catch (exception) {
      throw SAFException(
        code: exception.code,
        message: exception.message ?? 'Unknown error',
        details: exception.details,
      );
    }
  }
}
