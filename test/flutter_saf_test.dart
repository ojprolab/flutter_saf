import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_saf/flutter_saf.dart';
import 'package:flutter_saf/flutter_saf_platform_interface.dart';
import 'package:flutter_saf/flutter_saf_method_channel.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';

class MockFlutterSafPlatform
    with MockPlatformInterfaceMixin
    implements FlutterSafPlatform {

  @override
  Future<String?> getPlatformVersion() => Future.value('42');
}

void main() {
  final FlutterSafPlatform initialPlatform = FlutterSafPlatform.instance;

  test('$MethodChannelFlutterSaf is the default instance', () {
    expect(initialPlatform, isInstanceOf<MethodChannelFlutterSaf>());
  });

  test('getPlatformVersion', () async {
    FlutterSaf flutterSafPlugin = FlutterSaf();
    MockFlutterSafPlatform fakePlatform = MockFlutterSafPlatform();
    FlutterSafPlatform.instance = fakePlatform;

    expect(await flutterSafPlugin.getPlatformVersion(), '42');
  });
}
