import 'package:flutter/services.dart';
import 'package:flutter_saf/flutter_saf.dart';
import 'package:flutter_saf/flutter_saf_method_channel.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('flutter_saf');
  final platform = MethodChannelFlutterSaf();
  final calls = <MethodCall>[];
  Object? reply;

  setUp(() {
    calls.clear();
    reply = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      final value = reply;
      if (value is PlatformException) throw value;
      return value;
    });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  MethodCall single() {
    expect(calls, hasLength(1));
    return calls.single;
  }

  group('pickDirectory', () {
    test('omits initialUri when not given', () async {
      await platform.pickDirectory();

      expect(single().method, 'pickDirectory');
      expect(single().arguments, <String, dynamic>{});
    });

    test('maps the picked directory', () async {
      reply = {
        'uri': 'content://tree/books',
        'name': 'Books',
        'storageType': 'primary',
      };

      final dir = await platform.pickDirectory(initialUri: 'content://hint');

      expect(single().arguments, {'initialUri': 'content://hint'});
      expect(dir?.uri, 'content://tree/books');
      expect(dir?.name, 'Books');
      expect(dir?.storageType, 'primary');
    });

    test('returns null when the user cancels', () async {
      expect(await platform.pickDirectory(), isNull);
    });
  });

  group('scanDirectory', () {
    test('sends defaults and drops unset optional filters', () async {
      reply = <Map>[];

      await platform.scanDirectory('content://tree/books');

      expect(single().method, 'scanDirectory');
      expect(single().arguments, {
        'uri': 'content://tree/books',
        'recursive': true,
        'includeHidden': false,
        'sortDescending': false,
      });
    });

    test('sends every filter that is set', () async {
      reply = <Map>[];

      await platform.scanDirectory(
        'content://tree/books',
        extensions: ['epub', 'pdf'],
        recursive: false,
        taskId: 'task-1',
        includeHidden: true,
        minSize: 10,
        maxSize: 20,
        sortBy: SortBy.lastModified,
        sortDescending: true,
        limit: 5,
      );

      expect(single().arguments, {
        'uri': 'content://tree/books',
        'recursive': false,
        'includeHidden': true,
        'sortDescending': true,
        'extensions': ['epub', 'pdf'],
        'taskId': 'task-1',
        'minSize': 10,
        'maxSize': 20,
        'sortBy': 'lastModified',
        'limit': 5,
      });
    });

    test('an empty extensions list means all files', () async {
      reply = <Map>[];

      await platform.scanDirectory('content://tree/books', extensions: []);

      expect((single().arguments as Map).containsKey('extensions'), isFalse);
    });

    test('maps every returned file', () async {
      reply = [
        {
          'uri': 'content://doc/1',
          'name': 'Naval.EPUB',
          'size': 2048,
          'lastModified': 1700000000000,
          'mimeType': 'application/epub+zip',
        },
        {'uri': 'content://doc/2', 'name': 'notes.pdf', 'size': 10},
      ];

      final files = await platform.scanDirectory('content://tree/books');

      expect(files, hasLength(2));
      expect(files![0].uri, 'content://doc/1');
      expect(files[0].size, 2048);
      expect(files[0].extension, 'epub');
      expect(files[1].lastModified, 0);
    });

    test('returns null when native returns null', () async {
      expect(await platform.scanDirectory('content://tree/books'), isNull);
    });
  });

  group('file reads', () {
    test('readBytesAt sends the range', () async {
      reply = Uint8List.fromList([1, 2, 3]);

      final bytes = await platform.readBytesAt('content://doc/1', 4096, 3);

      expect(single().method, 'readBytesAt');
      expect(single().arguments, {
        'uri': 'content://doc/1',
        'position': 4096,
        'size': 3,
      });
      expect(bytes, [1, 2, 3]);
    });

    test('readFileBytes sends optional limits only when set', () async {
      await platform.readFileBytes('content://doc/1');
      await platform.readFileBytes(
        'content://doc/1',
        taskId: 't',
        maxBytes: 100,
      );

      expect(calls[0].arguments, {'uri': 'content://doc/1'});
      expect(calls[1].arguments, {
        'uri': 'content://doc/1',
        'taskId': 't',
        'maxBytes': 100,
      });
    });

    test('copyFileToPath sends defaults and returns the destination', () async {
      reply = '/data/books/a.epub';

      final dest = await platform.copyFileToPath(
        'content://doc/1',
        '/data/books/a.epub',
      );

      expect(single().arguments, {
        'uri': 'content://doc/1',
        'destPath': '/data/books/a.epub',
        'overwrite': true,
        'bufferSize': 32768,
      });
      expect(dest, '/data/books/a.epub');
    });
  });

  group('single-uri calls', () {
    final cases = <String, Future<Object?> Function(String uri)>{
      'checkAccess': platform.checkAccess,
      'deleteFile': platform.deleteFile,
      'exists': platform.exists,
      'releasePermission': platform.releasePermission,
    };

    for (final MapEntry(key: method, value: invoke) in cases.entries) {
      test('$method sends only the uri', () async {
        reply = true;

        expect(await invoke('content://doc/1'), isTrue);
        expect(single().method, method);
        expect(single().arguments, {'uri': 'content://doc/1'});
      });
    }
  });

  test('renameFile sends only the target that is given', () async {
    reply = 'content://doc/renamed';

    final uri = await platform.renameFile('content://doc/1', newName: 'b.pdf');

    expect(single().arguments, {'uri': 'content://doc/1', 'newName': 'b.pdf'});
    expect(uri, 'content://doc/renamed');
  });

  test('getFileMetadata maps the result', () async {
    reply = {
      'uri': 'content://doc/1',
      'name': 'a.pdf',
      'size': 5,
      'isDirectory': false,
      'isWritable': true,
    };

    final meta = await platform.getFileMetadata('content://doc/1');

    expect(meta?.size, 5);
    expect(meta?.isWritable, isTrue);
    expect(meta?.lastModified, 0);
  });

  test('hashFile sends only the uri and returns the digest', () async {
    reply = 'ba7816bf';

    final digest = await platform.hashFile('content://doc/1');

    expect(single().method, 'hashFile');
    expect(single().arguments, {'uri': 'content://doc/1'});
    expect(digest, 'ba7816bf');
  });

  test('renameFile sends destPath when given', () async {
    reply = '/books/b.pdf';

    await platform.renameFile('/books/a.pdf', destPath: '/books/b.pdf');

    expect(single().arguments, {
      'uri': '/books/a.pdf',
      'destPath': '/books/b.pdf',
    });
  });

  test('native errors reach the caller as PlatformException', () async {
    reply = PlatformException(code: 'PERMISSION_ERROR', message: 'revoked');

    expect(
      () => platform.readBytesAt('content://doc/1', 0, 10),
      throwsA(
        isA<PlatformException>().having(
          (e) => e.code,
          'code',
          'PERMISSION_ERROR',
        ),
      ),
    );
  });
}
