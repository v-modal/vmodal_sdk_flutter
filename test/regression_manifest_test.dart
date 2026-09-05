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
      'dartdoc_options.yaml',
      'release_note.md',
      'lib/vmodal_sdk_flutter.dart',
      'lib/src/client.dart',
      'lib/src/content_scope.dart',
      'lib/src/transport.dart',
      'lib/src/upload.dart',
      'lib/src/adaptive_upload.dart',
      'lib/src/vmodal.dart',
      'lib/src/routes.g.dart',
      'tool/check_route_sync.dart',
      'tool/release_manifest.dart',
      'example/readme.md',
      'example/01_full_app/lib/main.dart',
      'example/02_users/README.md',
      'example/02_users/lib/user_examples.dart',
      'example/02_users/test/user_examples_test.dart',
      'example/03_cctv/README.md',
      'example/03_cctv/bin/main.dart',
      'example/03_cctv/lib/cctv_example.dart',
      'example/03_cctv/test/cctv_example_test.dart',
      'example/04_example/README.md',
      'example/04_example/lib/main.dart',
      'example/04_example/test/widget_test.dart',
      'test/new_api_surface_test.dart',
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
      expect(File('tool/gen_routes.dart').existsSync(), isTrue);
      expect(File('tool/routes_manifest.dart').existsSync(), isTrue);
    }
    expect(
      File('docs/sdk_contract.md').existsSync() ||
          File('doc/sdk_contract.md').existsSync(),
      isTrue,
      reason: 'SDK contract documentation',
    );
  });

  test('dartdoc exposes only the public library', () {
    final text = File('dartdoc_options.yaml').readAsStringSync();
    expect(text, contains('include:'));
    expect(text, contains('- vmodal_sdk_flutter'));
    expect(text, contains('nodoc:'));
    expect(text, contains('- lib/src/http.dart'));
    expect(text, contains('- lib/src/routes.dart'));
    expect(text, contains('- ambiguous-doc-reference'));
    expect(text, contains('- broken-link'));
    expect(text, contains('- unresolved-doc-reference'));
    final api = File('lib/vmodal_sdk_flutter.dart').readAsStringSync();
    expect(
      api,
      contains(
        "export 'src/routes.dart' show RouteCategory, RouteSpec, Routes;",
      ),
      reason: 'documentation exclusions must not remove runtime exports',
    );
  });

  test('package publication excludes internal documentation artifacts', () {
    final text = File('.pubignore').readAsStringSync();
    for (final path in <String>[
      'docs/todo/',
      'docs_sdk/',
      'docs.py',
      'utils.py',
      'test/routes_gen_test.dart',
      'tool/gen_routes.dart',
      'tool/routes_manifest.dart',
    ]) {
      expect(text, contains(path), reason: path);
    }
    expect(text, isNot(contains('dartdoc_options.yaml')));
    expect(text, isNot(contains('release_note.md')));
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
      expect(File('${dir.path}/dartdoc_options.yaml').existsSync(), isTrue);
      expect(File('${dir.path}/release_note.md').existsSync(), isTrue);
      expect(File('${dir.path}/.gitleaks.toml').existsSync(), isTrue);
      for (final path in <String>[
        'install.sh',
        'build.sh',
        'run.sh',
        'test.sh',
        'tool/live_test.dart',
        'tool/perf_benchmark.dart',
        'example/readme.md',
        'example/01_full_app/README.md',
        'example/01_full_app/lib/main.dart',
        'example/01_full_app/asset/video_10frames.mp4',
        'example/02_users/README.md',
        'example/02_users/lib/global_search_index.dart',
        'example/02_users/lib/private_user_index.dart',
        'example/02_users/lib/user_streams.dart',
        'example/02_users/lib/product_catalog.dart',
        'example/02_users/test/user_examples_test.dart',
        'example/03_cctv/README.md',
        'example/03_cctv/bin/main.dart',
        'example/03_cctv/lib/cctv_example.dart',
        'example/03_cctv/test/cctv_example_test.dart',
        'example/04_example/README.md',
        'example/04_example/lib/main.dart',
        'example/04_example/test/widget_test.dart',
        'doc/search_app.md',
        'doc/sdk_doc.md',
        'doc/manage_api_key.md',
        'doc/sdk_contract.md',
      ]) {
        expect(File('${dir.path}/$path').existsSync(), isTrue, reason: path);
      }
      final exampleReadme = File(
        '${dir.path}/example/01_full_app/README.md',
      ).readAsStringSync();
      final searchGuide = File(
        '${dir.path}/doc/search_app.md',
      ).readAsStringSync();
      expect(exampleReadme, contains('client.images.getUrlBulk'));
      expect(exampleReadme, contains('responsive result grid'));
      expect(searchGuide, contains('input_index'));
      expect(searchGuide, contains('NetworkImage'));
      for (final path in <String>[
        'example/01_full_app/android/local.properties',
        'example/01_full_app/android/gradle/wrapper/gradle-wrapper.jar',
        'example/01_full_app/android/gradlew',
        'example/01_full_app/android/app/src/main/java/io/flutter/plugins/GeneratedPluginRegistrant.java',
        'example/01_full_app/.idea',
        'example/01_full_app/vmodal_example.iml',
        'example/01_full_app/ios/Flutter/Generated.xcconfig',
        'example/01_full_app/ios/Flutter/flutter_export_environment.sh',
        'example/01_full_app/ios/Flutter/ephemeral',
        'example/01_full_app/ios/Runner/GeneratedPluginRegistrant.h',
        'example/01_full_app/ios/Runner/GeneratedPluginRegistrant.m',
        'example/02_users/.dart_tool',
        'example/02_users/build',
        'example/03_cctv/.dart_tool',
        'example/03_cctv/build',
        'doc/todo/sdk_doc.md',
        'docs_sdk',
        'docs.py',
        'utils.py',
        'test/routes_gen_test.dart',
        'tool/gen_routes.dart',
        'tool/routes_manifest.dart',
      ]) {
        expect(
          FileSystemEntity.typeSync('${dir.path}/$path'),
          FileSystemEntityType.notFound,
        );
      }
    },
  );
}
