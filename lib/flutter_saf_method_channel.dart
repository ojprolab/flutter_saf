import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_saf/exceptions/saf_exception.dart';
import 'package:flutter_saf/models/saf_directory.dart';

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
}
