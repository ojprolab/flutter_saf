import 'dart:io';

import 'package:flutter_saf/flutter_saf.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  final saf = FlutterSaf();
  late Directory dir;
  late File source;
  final bytes = List<int>.generate(10000, (i) => i % 251);

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('flutter_saf_it_');
    source = File('${dir.path}/book.epub');
    await source.writeAsBytes(bytes);
  });

  tearDown(() => dir.delete(recursive: true));

  testWidgets('plain file paths are readable', (tester) async {
    expect(await saf.checkAccess(source.path), isTrue);
    expect(await saf.checkAccess(Uri.file(source.path).toString()), isTrue);
    expect(await saf.checkAccess('${dir.path}/missing.epub'), isFalse);
  });

  testWidgets('readBytesAt returns the requested range', (tester) async {
    final chunk = await saf.readBytesAt(source.path, 4000, 16);

    expect(chunk, bytes.sublist(4000, 4016));
  });

  testWidgets('readBytesAt past the end returns what is left', (tester) async {
    final chunk = await saf.readBytesAt(source.path, 9990, 64);

    expect(chunk, bytes.sublist(9990));
  });

  testWidgets('copyFileToPath copies every byte of a file uri', (tester) async {
    final dest = '${dir.path}/copy.epub';

    final copied =
        await saf.copyFileToPath(Uri.file(source.path).toString(), dest);

    expect(copied, dest);
    expect(await File(dest).readAsBytes(), bytes);
  });

  testWidgets('exists tells existing and missing files apart', (tester) async {
    expect(await saf.exists(source.path), isTrue);
    expect(await saf.exists('${dir.path}/missing.epub'), isFalse);
  });
}
