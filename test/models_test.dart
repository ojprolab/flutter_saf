import 'package:flutter_saf/flutter_saf.dart';
import 'package:flutter_saf/models/saf_directory.dart';
import 'package:flutter_saf/models/saf_file.dart';
import 'package:flutter_saf/models/saf_file_metadata.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('SAFFile', () {
    test('fromMap fills defaults for missing fields', () {
      final file = SAFFile.fromMap({});

      expect(file.uri, '');
      expect(file.size, 0);
      expect(file.lastModified, 0);
      expect(file.isWritable, isFalse);
      expect(file.name, isNull);
    });

    test('fromMap accepts numbers sent as doubles', () {
      final file =
          SAFFile.fromMap({'uri': 'u', 'size': 12.0, 'lastModified': 3.0});

      expect(file.size, 12);
      expect(file.lastModified, 3);
    });

    test('toMap round-trips', () {
      const file = SAFFile(
        uri: 'content://doc/1',
        name: 'a.epub',
        path: '/Books/a.epub',
        size: 10,
        mimeType: 'application/epub+zip',
        lastModified: 99,
        isWritable: true,
      );

      final copy = SAFFile.fromMap(file.toMap());

      expect(copy.toMap(), file.toMap());
    });

    test('extension is lowercase and empty without a dot or name', () {
      SAFFile named(String? name) =>
          SAFFile(uri: 'u', size: 0, lastModified: 0, name: name);

      expect(named('Book.EPUB').extension, 'epub');
      expect(named('archive.tar.gz').extension, 'gz');
      expect(named('README').extension, '');
      expect(named(null).extension, '');
    });

    test('formattedSize picks the right unit', () {
      SAFFile sized(int size) => SAFFile(uri: 'u', size: size, lastModified: 0);

      expect(sized(512).formattedSize, '512 B');
      expect(sized(1536).formattedSize, '1.5 KB');
      expect(sized(5 * 1024 * 1024).formattedSize, '5.0 MB');
      expect(sized(3 * 1024 * 1024 * 1024).formattedSize, '3.00 GB');
    });

    test('lastModifiedDate is UTC', () {
      const file = SAFFile(uri: 'u', size: 0, lastModified: 0);

      expect(file.lastModifiedDate, DateTime.utc(1970));
    });
  });

  group('SAFDirectory', () {
    test('round-trips through a map', () {
      const dir = SAFDirectory(
        uri: 'content://tree/books',
        name: 'Books',
        bookmarkKey: 'bm',
        storageType: 'sd',
      );

      expect(SAFDirectory.fromMap(dir.toMap()).toMap(), dir.toMap());
    });
  });

  group('SAFFileMetadata', () {
    test('fromMap fills defaults for missing fields', () {
      final meta = SAFFileMetadata.fromMap({'uri': 'u'});

      expect(meta.size, 0);
      expect(meta.isDirectory, isFalse);
      expect(meta.isWritable, isFalse);
    });
  });

  group('ScanProgress', () {
    test('done and indeterminate states', () {
      ScanProgress of(double progress, String status) =>
          ScanProgress(taskId: 't', progress: progress, status: status);

      expect(of(1, 'done').isDone, isTrue);
      expect(of(0, 'running').isIndeterminate, isTrue);
      expect(of(0, 'done').isIndeterminate, isFalse);
      expect(of(0.4, 'running').isIndeterminate, isFalse);
    });

    test('fromMap tolerates missing fields', () {
      final progress = ScanProgress.fromMap({'progress': 1});

      expect(progress.taskId, '');
      expect(progress.progress, 1.0);
      expect(progress.status, '');
    });
  });
}
