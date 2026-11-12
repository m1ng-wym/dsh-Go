// The golden layout must be host-aware: macOS compares against
// `goldens/macos/` while Linux keeps the committed Linux baselines.

import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'platform_goldens.dart';

void main() {
  group('platformGoldenUri', () {
    test('macOS maps a golden to goldens/macos', () {
      expect(
        platformGoldenUri(Uri.parse('goldens/chat_light.png'), isMacOS: true),
        Uri.parse('goldens/macos/chat_light.png'),
      );
    });

    test('macOS keeps the subdirectory of a nested golden', () {
      expect(
        platformGoldenUri(Uri.parse('goldens/dock/panel.png'), isMacOS: true),
        Uri.parse('goldens/macos/dock/panel.png'),
      );
    });

    test('macOS leaves keys outside goldens/ unchanged', () {
      expect(
        platformGoldenUri(Uri.parse('fixtures/chat_light.png'), isMacOS: true),
        Uri.parse('fixtures/chat_light.png'),
      );
      expect(platformGoldenUri(Uri.parse('chat_light.png'), isMacOS: true), Uri.parse('chat_light.png'));
    });

    test('macOS mapping is idempotent', () {
      expect(
        platformGoldenUri(Uri.parse('goldens/macos/chat_light.png'), isMacOS: true),
        Uri.parse('goldens/macos/chat_light.png'),
      );
    });

    test('Linux keeps the existing path', () {
      expect(
        platformGoldenUri(Uri.parse('goldens/chat_light.png'), isMacOS: false),
        Uri.parse('goldens/chat_light.png'),
      );
    });
  });

  test('macOS comparator writes under goldens/macos only', () async {
    final dir = await Directory.systemTemp.createTemp('goldens_platform_');
    addTearDown(() => dir.delete(recursive: true));
    final inner = LocalFileComparator(dir.uri.resolve('widget_test.dart'));
    final comparator = MacOsGoldenFileComparator(inner);
    final bytes = Uint8List.fromList([1, 2, 3]);

    await comparator.update(Uri.parse('goldens/one.png'), bytes);
    await comparator.update(Uri.parse('goldens/dock/two.png'), bytes);
    await comparator.update(Uri.parse('fixtures/ignore.png'), bytes);

    expect(File('${dir.path}/goldens/macos/one.png').existsSync(), isTrue);
    expect(File('${dir.path}/goldens/macos/dock/two.png').existsSync(), isTrue);
    expect(File('${dir.path}/goldens/one.png').existsSync(), isFalse);
    expect(File('${dir.path}/fixtures/ignore.png').existsSync(), isTrue);
  });
}
