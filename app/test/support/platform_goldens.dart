// macOS golden layout.
//
// Golden baselines are rendered by the host toolchain; Linux and macOS do not
// produce the same pixels for the same widget, so macOS baselines live beside
// the Linux ones under `goldens/macos/`. On macOS a golden key
// `goldens/<name>` resolves to `goldens/macos/<name>`; on every other host the
// key is left untouched.

import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

/// Directory (inside every test's `goldens/`) that holds macOS baselines.
const macOsGoldenDir = 'macos';

const _goldensPrefix = 'goldens/';
const _macOsPrefix = '$_goldensPrefix$macOsGoldenDir/';

/// Resolves [golden] to the baseline this host compares against.
///
/// Only keys below `goldens/` are layout-dependent; anything else (fixtures,
/// absolute URLs, keys already inside `goldens/macos/`) is returned unchanged
/// so re-wrapping the comparator is idempotent.
Uri platformGoldenUri(Uri golden, {required bool isMacOS}) {
  if (!isMacOS) return golden;
  final path = golden.path;
  if (!path.startsWith(_goldensPrefix) || path.startsWith(_macOsPrefix)) {
    return golden;
  }
  return golden.replace(path: '$_macOsPrefix${path.substring(_goldensPrefix.length)}');
}

/// Installs the platform golden layout over flutter_test's comparator.
///
/// The wrapper stays a [LocalFileComparator], so `english_preview.dart` (which
/// wraps any LocalFileComparator to redirect writes) composes with it.
void setUpPlatformGoldens({bool? isMacOS}) {
  if (!(isMacOS ?? Platform.isMacOS)) return;
  final current = goldenFileComparator;
  if (current is LocalFileComparator && current is! MacOsGoldenFileComparator) {
    goldenFileComparator = MacOsGoldenFileComparator(current);
  }
}

/// The comparator that redirects golden keys to [macOsGoldenDir].
class MacOsGoldenFileComparator extends LocalFileComparator {
  MacOsGoldenFileComparator(LocalFileComparator inner) : super(inner.basedir.resolve('platform_goldens_test.dart'));

  @override
  Future<bool> compare(Uint8List imageBytes, Uri golden) =>
      super.compare(imageBytes, platformGoldenUri(golden, isMacOS: true));

  @override
  Future<void> update(Uri golden, Uint8List imageBytes) =>
      super.update(platformGoldenUri(golden, isMacOS: true), imageBytes);
}
