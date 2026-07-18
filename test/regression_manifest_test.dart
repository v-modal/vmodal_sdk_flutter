import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('regression manifest covers every implemented step in order', () {
    final text = File('test.sh').readAsStringSync();
    const steps = <String>[
      'S04',
      'S05',
      'S06',
      'S07',
      'S08',
      'S09',
      'S10',
      'S11_1',
      'S11_2',
      'S11_3',
      'S11_4',
      'S11_5',
      'S11_6',
      'S11',
      'S12',
      'S13',
      'S14',
      'S15',
      'S16',
      'S17',
      'S18',
      'S19',
    ];
    for (final step in steps) {
      expect(text, contains(step));
    }
    expect(
      text.indexOf('config_routes_test.dart'),
      lessThan(text.indexOf('adaptive_upload_test.dart')),
    );
    expect(
      text.indexOf('adaptive_upload_test.dart'),
      lessThan(text.indexOf('security_check.sh all')),
    );
  });

  test('required implementation and release artifacts exist', () {
    const files = <String>[
      'lib/vmodal_sdk_flutter.dart',
      'lib/src/client.dart',
      'lib/src/transport.dart',
      'lib/src/upload.dart',
      'lib/src/adaptive_upload.dart',
      'tool/check_route_sync.dart',
      'tool/release_manifest.dart',
      'example/lib/main.dart',
    ];
    for (final path in files) {
      expect(File(path).existsSync(), isTrue, reason: path);
    }
    expect(
      File('release/public_publish.yml').existsSync() ||
          File('.github/workflows/publish.yml').existsSync(),
      isTrue,
      reason: 'public publish workflow',
    );
    if (Directory('docs').existsSync()) {
      expect(File('tool/live_test.dart').existsSync(), isTrue);
    }
    expect(
      File('docs/sdk_contract.md').existsSync() ||
          File('doc/sdk_contract.md').existsSync(),
      isTrue,
      reason: 'SDK contract documentation',
    );
  });

  test('default all suite remains offline', () {
    final text = File('test.sh').readAsStringSync();
    final body = RegExp(
      r'sdk_all\(\) \{([\s\S]*?)\n\}',
    ).firstMatch(text)!.group(1)!;
    expect(body, isNot(contains('sdk_live')));
    expect(body, contains('sdk_test'));
    expect(body, contains('sdk_package'));
    expect(body, contains('sdk_sim'));
  });

  test(
    'source export keeps lockfile and excludes generated platform files',
    () async {
      final dir = Directory.systemTemp.createTempSync('vmodal-export-test.');
      addTearDown(() => dir.deleteSync(recursive: true));
      final bin = await Process.run('bash', <String>['install.sh', 'dart_bin']);
      expect(bin.exitCode, 0, reason: '${bin.stderr}');
      final result = await Process.run('${bin.stdout}'.trim(), <String>[
        'run',
        'tool/release_manifest.dart',
        'export',
        dir.path,
      ]);
      expect(result.exitCode, 0, reason: '${result.stderr}');
      expect(File('${dir.path}/pubspec.lock').existsSync(), isTrue);
      for (final path in <String>[
        'install.sh',
        'build.sh',
        'run.sh',
        'test.sh',
        'tool/live_test.dart',
      ]) {
        expect(File('${dir.path}/$path').existsSync(), isTrue, reason: path);
      }
      for (final path in <String>[
        'example/android/local.properties',
        'example/android/gradle/wrapper/gradle-wrapper.jar',
        'example/android/gradlew',
        'example/android/app/src/main/java/io/flutter/plugins/GeneratedPluginRegistrant.java',
        'example/.idea',
        'example/vmodal_example.iml',
        'example/ios/Flutter/Generated.xcconfig',
        'example/ios/Flutter/flutter_export_environment.sh',
        'example/ios/Flutter/ephemeral',
        'example/ios/Runner/GeneratedPluginRegistrant.h',
        'example/ios/Runner/GeneratedPluginRegistrant.m',
      ]) {
        expect(
          FileSystemEntity.typeSync('${dir.path}/$path'),
          FileSystemEntityType.notFound,
        );
      }
    },
  );
}
