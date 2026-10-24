import 'package:flutter/services.dart';
import 'package:flutter_saf/flutter_saf.dart';
import 'package:flutter_saf/flutter_saf_method_channel.dart';
import 'package:flutter_saf/flutter_saf_platform_interface.dart';
import 'package:flutter_saf/models/saf_file.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';

class FakeFlutterSafPlatform extends FlutterSafPlatform
    with MockPlatformInterfaceMixin {
  bool? boolReply;
  final calls = <String>[];

  @override
  Future<bool?> checkAccess(String uri) async {
    calls.add('checkAccess $uri');
    return boolReply;
  }

  @override
  Future<bool?> deleteFile(String uri) async {
    calls.add('deleteFile $uri');
    return boolReply;
  }

  @override
  Future<bool?> exists(String uri) async {
    calls.add('exists $uri');
    return boolReply;
  }

  @override
  Future<bool?> releasePermission(String uri) async {
    calls.add('releasePermission $uri');
    return boolReply;
  }

  @override
  Future<String?> hashFile(String uri) async {
    calls.add('hashFile $uri');
    return 'digest';
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
    calls.add('scanDirectory $uri $extensions $recursive $sortBy $limit');
    return const [];
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final initialPlatform = FlutterSafPlatform.instance;
  late FakeFlutterSafPlatform fake;
  final saf = FlutterSaf();

  setUp(() {
    fake = FakeFlutterSafPlatform();
    FlutterSafPlatform.instance = fake;
  });

  test('$MethodChannelFlutterSaf is the default instance', () {
    expect(initialPlatform, isA<MethodChannelFlutterSaf>());
  });

  group('boolean calls never return null', () {
    final cases = <String, Future<bool> Function(String uri)>{
      'checkAccess': saf.checkAccess,
      'deleteFile': saf.deleteFile,
      'exists': saf.exists,
      'releasePermission': saf.releasePermission,
    };

    for (final MapEntry(key: method, value: invoke) in cases.entries) {
      test('$method treats a null reply as false', () async {
        fake.boolReply = null;

        expect(await invoke('content://doc/1'), isFalse);
        expect(fake.calls, ['$method content://doc/1']);
      });

      test('$method passes true through', () async {
        fake.boolReply = true;

        expect(await invoke('content://doc/1'), isTrue);
      });
    }
  });

  test('scanDirectory forwards every option to the platform', () async {
    await saf.scanDirectory(
      'content://tree/books',
      extensions: ['epub'],
      recursive: false,
      sortBy: SortBy.size,
      limit: 3,
    );

    expect(fake.calls, [
      'scanDirectory content://tree/books [epub] false SortBy.size 3',
    ]);
  });

  test('hashFile forwards the uri to the platform', () async {
    expect(await saf.hashFile('content://doc/1'), 'digest');
    expect(fake.calls, ['hashFile content://doc/1']);
  });

  test('renameFile requires a new name or destination', () {
    expect(() => saf.renameFile('content://doc/1'), throwsAssertionError);
  });

  test('progress events from native reach the progress stream', () async {
    FlutterSaf.initialize();
    final events = <ScanProgress>[];
    final sub = FlutterSaf.progress.listen(events.add);
    addTearDown(sub.cancel);

    await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .handlePlatformMessage(
      'flutter_saf',
      const StandardMethodCodec().encodeMethodCall(
        const MethodCall('onProgress', {
          'taskId': 'scan-1',
          'progress': 0.5,
          'status': 'running',
        }),
      ),
      (_) {},
    );
    await Future<void>.delayed(Duration.zero);

    expect(events, hasLength(1));
    expect(events.single.taskId, 'scan-1');
    expect(events.single.progress, 0.5);
    expect(events.single.isDone, isFalse);
  });
}
