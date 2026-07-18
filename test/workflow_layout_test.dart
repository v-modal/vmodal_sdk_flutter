import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

final internalFile = File(
  '../../.github/workflows/sdk_flutter_test_release.yml',
);
final internal = internalFile.existsSync()
    ? internalFile.readAsStringSync()
    : '';
final publicFile = File('release/public_publish.yml').existsSync()
    ? File('release/public_publish.yml')
    : File('.github/workflows/publish.yml');
final public = publicFile.readAsStringSync();
final androidProperties = File(
  'example/android/gradle.properties',
).readAsStringSync();
final androidSettings = File(
  'example/android/settings.gradle.kts',
).readAsStringSync();
final examplePubspec = File('example/pubspec.yaml').readAsStringSync();

void checkWorkflow(String main, String tagged) {
  const releaseOnly =
      "if: \${{ github.event_name == 'workflow_dispatch' && !inputs.publish_sdk_docs_only && (inputs.publish_sdk_flutter || inputs.publish_pub_dev) }}";
  const publishDocs =
      "if: \${{ github.event_name == 'workflow_dispatch' && (inputs.publish_sdk_flutter || inputs.publish_pub_dev || inputs.publish_sdk_docs_only) }}";
  const buildDocs =
      "if: \${{ always() && github.event_name == 'workflow_dispatch' && (inputs.publish_sdk_flutter || inputs.publish_pub_dev || inputs.publish_sdk_docs_only) && needs.secret_detection.result == 'success' && (inputs.publish_sdk_docs_only || needs.publish_sdk_flutter.result == 'success') }}";
  expect(main, contains('name: sdk_flutter_test_release'));
  expect(main, contains('publish_sdk_flutter:'));
  expect(main, contains('publish_pub_dev:'));
  expect(main, contains('publish_sdk_docs_only:'));
  expect(main, contains('description: Publish only the Flutter SDK reference'));
  expect(main, contains('default: true'));
  expect(main, contains('group: sdk_flutter_release_\${{ github.ref }}'));
  expect(main, contains('WORKDIR: uinterface/sdk_flutter'));
  expect(main, contains('# RELEASE_SHA: \${{ github.sha }}'));
  expect(main, isNot(contains('\n  RELEASE_SHA: \${{ github.sha }}')));
  expect(main, isNot(contains('\n          ref: \${{ env.RELEASE_SHA }}')));
  expect(
    main,
    isNot(
      contains('\n          test "\$(git rev-parse HEAD)" = "\$RELEASE_SHA"'),
    ),
  );
  expect(
    main,
    contains('secret_detection:\n    $publishDocs\n    runs-on: ubuntu-latest'),
  );
  expect(
    main,
    contains(
      'offline_test:\n    if: \${{ !inputs.publish_sdk_docs_only }}\n    runs-on: ubuntu-latest',
    ),
  );
  expect(
    main,
    contains(
      'live_test:\n    needs: [offline_test, example_android]\n    $releaseOnly',
    ),
  );
  expect(
    main,
    contains('pub_package:\n    needs: offline_test\n    $releaseOnly'),
  );
  expect(
    main,
    contains(
      'needs: [secret_detection, offline_test, example_android, example_ios, live_test, pub_package]',
    ),
  );
  expect(main, contains('needs: release_gate'));
  expect(main, contains('pub.dev publication requires source export.'));
  expect(
    main,
    contains(
      'if: \${{ !inputs.publish_sdk_docs_only && inputs.publish_pub_dev }}',
    ),
  );
  expect(main, contains('environment: sdk-flutter-production'));
  expect(main, contains('gitleaks_'));
  expect(main, contains('--source "\$WORKDIR"'));
  expect(main, isNot(contains('--log-opts=')));
  expect(main, contains('SHA256SUMS'));
  expect(main, contains('SOURCE_MANIFEST.sha256'));
  expect(
    main,
    contains('run tool/release_manifest.dart export "\$export_dir"'),
  );
  expect(main, contains('sha256sum --check SOURCE_MANIFEST.sha256'));
  expect(
    main,
    contains('git ls-files --error-unmatch install.sh build.sh run.sh test.sh'),
  );
  expect(main, contains('RELEASE_TOKEN: \${{ secrets.GH_TOKEN }}'));
  expect(main, isNot(contains('FLUTTER_SDK_APP_')));
  expect(main, contains('git push --atomic'));
  expect(
    main,
    contains(
      'if: \${{ !inputs.publish_sdk_docs_only && (inputs.publish_sdk_flutter || inputs.publish_pub_dev) }}',
    ),
  );
  expect(
    main,
    contains(
      'sdk_docs_artifact:\n    needs: [secret_detection, publish_sdk_flutter]\n    $buildDocs',
    ),
  );
  expect(
    main,
    contains(
      'publish_sdk_docs:\n    needs: sdk_docs_artifact\n    $publishDocs',
    ),
  );
  expect(main, contains('python "\$WORKDIR/docs.py" generate'));
  expect(main, contains('python "\$WORKDIR/docs.py" check'));
  expect(main, contains('bash "\$WORKDIR/install.sh" install'));
  expect(
    main,
    contains('python -m pip install --disable-pip-version-check fire==0.7.1'),
  );
  expect(main, contains('path: \${{ env.WORKDIR }}/docs_sdk'));
  expect(
    main,
    contains('sdk-flutter-docs-\${{ github.run_id }}-\${{ github.sha }}'),
  );
  expect(main, contains('"\$WORKDIR/docs_sdk/index.html"'));
  expect(main, contains('"\$WORKDIR/docs_sdk/index.json"'));
  expect(
    main,
    contains('"\$WORKDIR/docs_sdk/vmodal_sdk_flutter/VmodalClient-class.html"'),
  );
  expect(main, isNot(contains('PyYAML')));
  expect(main, isNot(contains('openapi-spec-validator')));
  expect(main.toLowerCase(), isNot(contains('swagger')));
  expect(main, contains('include-hidden-files: true'));
  expect(main, contains('DOCS_REPOSITORY: v-modal/vmodal_sdk_flutter'));
  expect(
    main,
    contains('DOCS_URL: https://v-modal.github.io/vmodal_sdk_flutter'),
  );
  expect(main, isNot(contains('gh repo create "\$DOCS_REPOSITORY"')));
  expect(main, contains('git push origin HEAD:gh-pages'));
  expect(main, contains('build_type:"legacy"'));
  expect(main, contains('repos/\$DOCS_REPOSITORY/pages'));
  expect(main, contains('"\$DOCS_URL/RELEASE_SHA"'));
  expect(main, contains('for attempt in {1..30}'));
  expect(main, contains('https://pub.dev/api/packages/vmodal_sdk_flutter'));
  expect(main, contains('dartdoc_options.yaml'));
  expect(main, contains("--exclude='todo'"));

  final actions = RegExp(
    r'uses:\s+[^\s]+@([^\s]+)',
  ).allMatches('$main\n$tagged');
  expect(actions, isNotEmpty);
  for (final action in actions) {
    expect(action.group(1), matches(RegExp(r'^[0-9a-f]{40}$')));
  }
  for (final checkout in RegExp(
    r'uses:\s+actions/checkout@[\s\S]*?(?=\n\s*- name:|\n\s*- uses:|\n\s*$)',
  ).allMatches('$main\n$tagged')) {
    expect(checkout.group(0), contains('persist-credentials: false'));
  }

  expect(main, isNot(contains('id-token: write')));
  expect(
    main.toLowerCase(),
    isNot(matches(RegExp(r'maven|\bosv\b|\bsbom\b|security_policy'))),
  );
  expect(main, isNot(contains('git merge')));
  expect(main, isNot(contains('git push --force')));
  expect(main, isNot(contains('--skip-validation')));

  expect(tagged, contains('name: publish_pub_dev'));
  expect(tagged, contains("- 'v[0-9]+.[0-9]+.[0-9]+'"));
  expect(tagged, isNot(contains('workflow_dispatch')));
  expect(tagged, contains('needs: verify_tagged_source'));
  expect(tagged, contains('environment: pub.dev'));
  expect(tagged, contains('id-token: write'));
  expect(tagged, contains('pub publish --force'));
  expect(tagged, isNot(contains('--skip-validation')));
  expect(tagged.toLowerCase(), isNot(contains('pub_token')));
}

void main() {
  test('Android example uses Flutter 3.44 AGP 9 compatibility mode', () {
    expect(androidProperties, contains('android.newDsl=false'));
    expect(androidProperties, contains('android.builtInKotlin=false'));
    expect(androidProperties, isNot(contains('android.builtInKotlin=true')));
    expect(
      androidSettings,
      contains('id("org.jetbrains.kotlin.android") version "2.3.20"'),
    );
    expect(examplePubspec, contains('file_selector: ^1.1.0'));
    expect(examplePubspec, isNot(contains('file_picker:')));
  });

  test('release workflows enforce tested-source causality', () {
    if (internal.isEmpty) return;
    checkWorkflow(internal, public);
  });

  test('floating action pin mutation fails', () {
    if (internal.isEmpty) return;
    final bad = internal.replaceFirst(
      RegExp(r'actions/checkout@[0-9a-f]{40}'),
      'actions/checkout@v4',
    );
    expect(() => checkWorkflow(bad, public), throwsA(isA<TestFailure>()));
  });

  test('publication shortcut mutation fails', () {
    if (internal.isEmpty) return;
    final bad = internal.replaceFirst(
      'needs: release_gate',
      'needs: offline_test',
    );
    expect(() => checkWorkflow(bad, public), throwsA(isA<TestFailure>()));
  });

  test('source export mutation fails', () {
    if (internal.isEmpty) return;
    final bad = internal.replaceFirst(
      'run tool/release_manifest.dart export "\$export_dir"',
      'run tool/release_manifest.dart check',
    );
    expect(() => checkWorkflow(bad, public), throwsA(isA<TestFailure>()));
  });

  test('stored publication token mutation fails', () {
    if (internal.isEmpty) return;
    final bad = '$public\n      PUB_TOKEN: \${{ secrets.PUB_TOKEN }}\n';
    expect(() => checkWorkflow(internal, bad), throwsA(isA<TestFailure>()));
  });
}
