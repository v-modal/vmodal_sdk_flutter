import 'dart:io';

import 'package:crypto/crypto.dart';

const generatedNames = <String>{
  '.dart_tool',
  '.flutter-plugins',
  '.flutter-plugins-dependencies',
  '.gradle',
  '.idea',
  '.last_build_id',
  '.packages',
  '.symlinks',
  'Generated.xcconfig',
  'GeneratedPluginRegistrant.h',
  'GeneratedPluginRegistrant.java',
  'GeneratedPluginRegistrant.m',
  'Pods',
  'build',
  'coverage',
  'ephemeral',
  'flutter_export_environment.sh',
  'gradle-wrapper.jar',
  'gradlew',
  'gradlew.bat',
  'local.properties',
};

bool isGeneratedName(String name) =>
    generatedNames.contains(name) || name.endsWith('.iml');

Future<void> main(List<String> args) async {
  final command = args.isEmpty ? 'check' : args.first;
  final root = Directory.current.absolute;
  final version = _version(root);
  _checkVersion(root, version);
  switch (command) {
    case 'check':
      stdout.writeln('release metadata OK: v$version');
      return;
    case 'export':
      if (args.length != 2) throw ArgumentError('export destination required');
      await _export(root, Directory(args[1]));
      stdout.writeln('source export OK: v$version');
      return;
    case 'manifest':
      await _manifest(args.length == 2 ? Directory(args[1]).absolute : root);
      stdout.writeln('source manifest OK: v$version');
      return;
    default:
      throw ArgumentError('unknown command');
  }
}

String _version(Directory root) {
  final text = File('${root.path}/pubspec.yaml').readAsStringSync();
  return RegExp(
        r'^version:\s*([^\s]+)',
        multiLine: true,
      ).firstMatch(text)?.group(1) ??
      (throw StateError('pubspec version missing'));
}

void _checkVersion(Directory root, String version) {
  final client = File('${root.path}/lib/src/client.dart').readAsStringSync();
  final changelog = File('${root.path}/CHANGELOG.md').readAsStringSync();
  if (!client.contains("vmodalSdkVersion = '$version'") ||
      !changelog.contains('## $version')) {
    throw StateError('version metadata mismatch');
  }
  if (!File('${root.path}/LICENSE').existsSync()) {
    throw StateError('license missing');
  }
}

Future<void> _export(Directory root, Directory destination) async {
  if (await destination.exists()) {
    await destination.delete(recursive: true);
  }
  await destination.create(recursive: true);
  const roots = <String>[
    'pubspec.yaml',
    'pubspec.lock',
    'analysis_options.yaml',
    'dartdoc_options.yaml',
    'LICENSE',
    'README.md',
    'readme_assets',
    'CHANGELOG.md',
    '.flutter-version',
    '.pubignore',
    'lib',
    'test',
    'example',
    'install.sh',
    'build.sh',
    'run.sh',
    'test.sh',
    'env.sh',
    'security_check.sh',
    'tool/flutter_checksums.txt',
    'tool/check_route_sync.dart',
    'tool/live_test.dart',
    'tool/release_manifest.dart',
  ];
  for (final name in roots) {
    final source = FileSystemEntity.typeSync('${root.path}/$name');
    if (source == FileSystemEntityType.file) {
      final target = File('${destination.path}/$name');
      await target.parent.create(recursive: true);
      await File('${root.path}/$name').copy(target.path);
    } else if (source == FileSystemEntityType.directory) {
      await _copyDirectory(
        Directory('${root.path}/$name'),
        Directory('${destination.path}/$name'),
        excluded: name == 'test'
            ? const <String>{'routes_gen_test.dart'}
            : const <String>{},
      );
    } else {
      throw StateError('export source missing: $name');
    }
  }
  final docs = Directory('${root.path}/docs').existsSync() ? 'docs' : 'doc';
  await _copyDirectory(
    Directory('${root.path}/$docs'),
    Directory('${destination.path}/doc'),
    excluded: const <String>{'todo'},
  );
  final publish = File('${root.path}/release/public_publish.yml').existsSync()
      ? File('${root.path}/release/public_publish.yml')
      : File('${root.path}/.github/workflows/publish.yml');
  final target = File('${destination.path}/.github/workflows/publish.yml');
  await target.parent.create(recursive: true);
  await publish.copy(target.path);
  await _manifest(destination);
}

Future<void> _copyDirectory(
  Directory source,
  Directory destination, {
  Set<String> excluded = const <String>{},
}) async {
  await destination.create(recursive: true);
  await for (final entity in source.list(recursive: false)) {
    final name = entity.uri.pathSegments
        .where((String value) => value.isNotEmpty)
        .last;
    if (excluded.contains(name) ||
        isGeneratedName(name) ||
        const <String>{'dev_plan.md', 'dev_plan_step.md'}.contains(name)) {
      continue;
    }
    if (entity is File) {
      await entity.copy('${destination.path}/$name');
    } else if (entity is Directory) {
      await _copyDirectory(
        entity,
        Directory('${destination.path}/$name'),
        excluded: excluded,
      );
    }
  }
}

Future<void> _manifest(Directory root) async {
  final rows = <String>[];
  await for (final entity in root.list(recursive: true, followLinks: false)) {
    final rel = entity.path.substring(root.path.length + 1);
    if (entity is! File ||
        entity.path.endsWith('/SOURCE_MANIFEST.sha256') ||
        entity.path.endsWith('/.gitignore')) {
      continue;
    }
    final names = rel.split(Platform.pathSeparator);
    if (entity.path.contains('/.git/') || names.any(isGeneratedName)) {
      continue;
    }
    final digest = sha256.convert(await entity.readAsBytes());
    rows.add('$digest  $rel');
  }
  rows.sort();
  await File(
    '${root.path}/SOURCE_MANIFEST.sha256',
  ).writeAsString('${rows.join('\n')}\n');
}
