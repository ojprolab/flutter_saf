import 'package:flutter_saf/models/saf_directory.dart';
import 'package:flutter_saf/models/saf_file.dart';

import 'flutter_saf_platform_interface.dart';

class FlutterSaf {
  /// Open a directory modal
  Future<SAFDirectory?> pickDirectory() {
    return FlutterSafPlatform.instance.pickDirectory();
  }

  /// Scan directory for files
  Future<List<SAFFile>?> scanDirectory(
    String uri, {
    List<String>? extensions,
    bool recursive = true,
  }) {
    return FlutterSafPlatform.instance.scanDirectory(
      uri,
      extensions: extensions,
      recursive: recursive,
    );
  }
}
