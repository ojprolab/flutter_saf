import 'package:flutter_saf/models/saf_directory.dart';

import 'flutter_saf_platform_interface.dart';

class FlutterSaf {
  Future<SAFDirectory?> pickDirectory() {
    return FlutterSafPlatform.instance.pickDirectory();
  }
}
