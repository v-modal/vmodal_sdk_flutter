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
final release = internal.isEmpty
    ? ''
    : File('ga_release.sh').readAsStringSync();
final androidProperties = File(
  'example/01_full_app/android/gradle.properties',
).readAsStringSync();
final androidSettings = File(
  'example/01_full_app/android/settings.gradle.kts',
).readAsStringSync();
final examplePubspec = File(
  'example/01_full_app/pubspec.yaml',
).readAsStringSync();

void checkWorkflow(String main, String script, String tagged) {
  const releaseOnly =
      "if: \${{ github.event_name == 'workflow_dispatch' && !inputs.publish_sdk_docs_only && (inputs.publish_sdk_flutter || inputs.publish_pub_dev) }}";
  const publishDocs =
      "if: \${{ github.event_name == 'workflow_dispatch' && (inputs.publish_sdk_flutter || inputs.publish_pub_dev || inputs.publish_sdk_docs_only) }}";
  const buildDocs =
      "if: \${{ always() && github.event_name == 'workflow_dispatch' && (inputs.publish_sdk_flutter || inputs.publish_pub_dev || inputs.publish_sdk_docs_only) && needs.secret_detection.result == 'success' && (inputs.publish_sdk_docs_only || needs.publish_sdk_flutter.result == 'success') }}";
  const publishBuiltDocs =
      "if: \${{ always() && github.event_name == 'workflow_dispatch' && (inputs.publish_sdk_flutter || inputs.publish_pub_dev || inputs.publish_sdk_docs_only) && needs.sdk_docs_artifact.result == 'success' }}";
  expect(main, contains('name: sdk_flutter_test_release'));
  expect(main, contains('publish_sdk_flutter:'));
  expect(main, contains('publish_pub_dev:'));
  expect(main, contains('publish_sdk_docs_only:'));
  expect(main, contains('description: Publish only the Flutter SDK reference'));
  expect(main, contains('default: true'));
  expect(main, contains('group: sdk_flutter_release_\${{ github.ref }}'));
  expect(main, contains('WORKDIR: uinterface/sdk_flutter'));
  expect(main, contains('GA_WORKSPACE: \${{ github.workspace }}'));
  expect(main, contains('RELEASE_SHA: \${{ github.sha }}'));
  expect(main, contains('PUBLIC_REPOSITORY: v-modal/vmodal_sdk_flutter'));
  expect(main, contains('DOCS_REPOSITORY: v-modal/vmodal_sdk_flutter'));
  expect(
    main,
    contains('DOCS_URL: https://v-modal.github.io/vmodal_sdk_flutter'),
  );
  expect(main, contains('GA_RELEASE_DIR: \${{ runner.temp }}'));
  expect(main, contains('VMODAL_ENV: prd'));
  expect(main, contains('INFISICAL_TOKEN: \${{ secrets.INFISICAL_TOKEN }}'));
  expect(
    main,
    contains('infs_assign VMODAL_API_KEY TEST_CLIENT_CLERK_USER_API_TOKEN'),
  );
  expect(main, contains('infs_assign RELEASE_TOKEN GH_TOKEN'));
  expect(main, contains('infs_assign GH_TOKEN GH_TOKEN'));
  expect(main, contains('token: \${{ env.GH_TOKEN }}'));
  expect(main, isNot(contains('\${{ secrets.GH_TOKEN }}')));
  expect(
    main,
    isNot(contains('\${{ secrets.TEST_CLIENT_CLERK_USER_API_TOKEN }}')),
  );
  expect(
    main,
    contains('source "\$GITHUB_WORKSPACE/vmx_api/.github/workflows/utils.sh"'),
  );
  expect(main, contains('PUBLISH_PUB_DEV: \${{ inputs.publish_pub_dev }}'));
  expect(main, isNot(contains('\n          ref: \${{ env.RELEASE_SHA }}')));

  final runs = RegExp(r'^\s+run:\s*(.+)$', multiLine: true).allMatches(main);
  expect(runs, isNotEmpty);
  for (final run in runs) {
    if (run.group(1) == '|') continue;
    expect(run.group(1), contains('ga_release.sh'));
  }
  final loads = RegExp(r'run: \|\n((?: {10}[^\n]*\n)+)').allMatches(main);
  expect(loads.length, 4);
  for (final load in loads) {
    expect(load.group(1), contains('.github/workflows/utils.sh'));
    expect(load.group(1), contains('infs_fetch_secret'));
    expect(load.group(1), contains('infs_assign'));
    expect(load.group(1), contains("trap 'unset INFISICAL_PAYLOAD' EXIT"));
  }
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
  expect(
    main,
    contains(
      'publish_sdk_flutter:\n    needs: '
      '[secret_detection, offline_test, example_android, example_ios, live_test, pub_package]',
    ),
  );
  expect(
    main,
    contains(
      'if: \${{ !inputs.publish_sdk_docs_only && inputs.publish_pub_dev }}',
    ),
  );
  expect(main, contains('environment: sdk-flutter-production'));
  expect(main, contains('ga_release.sh" ga_secret_detection'));
  expect(main, contains('ga_release.sh" ga_offline_test'));
  expect(main, contains('ga_release.sh" ga_example_android'));
  expect(main, contains('ga_release.sh" ga_example_ios'));
  expect(main, contains('ga_release.sh" ga_live_test "\$GITHUB_STEP_SUMMARY"'));
  expect(main, contains('ga_release.sh" ga_source_package'));
  expect(main, contains('ga_release.sh" ga_public_publish'));
  expect(main, contains('ga_release.sh" ga_docs_build'));
  expect(main, contains('ga_release.sh" ga_docs_publish'));
  expect(main, contains('ga_release.sh" ga_pub_dev_verify'));
  expect(main, isNot(contains('--log-opts=')));

  expect(script, contains('ga_secret_detection()'));
  expect(script, contains('bash security_check.sh secrets'));
  expect(script, contains('ga_offline_test()'));
  expect(script, contains('cd example/05_framebase_userlogin'));
  expect(script, contains('flutter_bin)" analyze'));
  expect(script, contains('flutter_bin)" test'));
  expect(script, contains('ga_source_package()'));
  expect(script, contains('SHA256SUMS'));
  expect(script, contains('SOURCE_MANIFEST.sha256'));
  expect(
    script,
    contains('run tool/release_manifest.dart export "\$export_dir"'),
  );
  expect(script, contains('sha256sum --check SOURCE_MANIFEST.sha256'));
  expect(
    script,
    contains(
      'sha256sum example/01_full_app/build/app/outputs/flutter-apk/app-debug.apk',
    ),
  );
  expect(script, contains("find example/01_full_app/build/ios -name '*.app'"));
  expect(
    script,
    contains(
      'sha256sum example/05_framebase_userlogin/build/app/outputs/flutter-apk/app-debug.apk',
    ),
  );
  expect(
    script,
    contains("find example/05_framebase_userlogin/build/ios -name '*.app'"),
  );
  expect(script, isNot(contains('sha256sum example/build/')));
  expect(script, isNot(contains('find example/build/ios')));
  expect(main, isNot(contains('FLUTTER_SDK_APP_')));
  expect(script, contains('git push --atomic'));
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
      'publish_sdk_docs:\n    needs: sdk_docs_artifact\n    $publishBuiltDocs',
    ),
  );
  expect(script, contains('python "\$GA_SCRIPT_DIR/docs.py" generate'));
  expect(script, contains('python "\$GA_SCRIPT_DIR/docs.py" check'));
  expect(script, contains('bash "\$GA_SCRIPT_DIR/install.sh" install'));
  expect(
    script,
    contains('python -m pip install --disable-pip-version-check fire==0.7.1'),
  );
  expect(main, contains('path: \${{ env.WORKDIR }}/doc'));
  expect(
    main,
    contains('sdk-flutter-docs-\${{ github.run_id }}-\${{ github.sha }}'),
  );
  expect(script, contains('"\$GA_SCRIPT_DIR/doc/index.html"'));
  expect(script, contains('"\$GA_SCRIPT_DIR/doc/index.json"'));
  expect(
    script,
    contains(
      '"\$GA_SCRIPT_DIR/doc/vmodal_sdk_flutter/VmodalClient-class.html"',
    ),
  );
  for (final name in <String>['VModal', 'VModalProject', 'VModalScope']) {
    expect(
      script,
      contains('"\$GA_SCRIPT_DIR/doc/vmodal_sdk_flutter/$name-class.html"'),
    );
    expect(
      script,
      contains('"\$site_dir/vmodal_sdk_flutter/$name-class.html"'),
    );
  }
  expect(main, isNot(contains('PyYAML')));
  expect(main, isNot(contains('openapi-spec-validator')));
  expect(main.toLowerCase(), isNot(contains('swagger')));
  expect(main, contains('include-hidden-files: true'));
  expect(script, isNot(contains('gh repo create "\$DOCS_REPOSITORY"')));
  expect(script, contains('git push origin HEAD:gh-pages'));
  expect(script, contains('build_type:"legacy"'));
  expect(script, contains('repos/\$DOCS_REPOSITORY/pages'));
  expect(script, contains('"\$DOCS_URL/RELEASE_SHA"'));
  expect(script, contains('for attempt in {1..30}'));
  expect(script, contains('https://pub.dev/api/packages/vmodal_sdk_flutter'));
  expect(script, contains("grep -Fx 'lib/vmodal_sdk_flutter.dart'"));
  expect(script, contains('dartdoc_options.yaml'));
  expect(script, contains('README.md release_note.md CHANGELOG.md'));
  expect(script, contains("--exclude='todo'"));
  expect(script, contains('git add -f pubspec.lock'));
  expect(
    script,
    contains(
      'git add -f example/05_framebase_userlogin/lib '
      'example/05_framebase_userlogin/pubspec.lock',
    ),
  );
  expect(script, contains('ga_require_env GA_RELEASE_DIR'));
  expect(script, contains('ga_require_env RELEASE_SHA'));
  expect(script, contains('ga_require_env RELEASE_TOKEN'));
  expect(script, contains('ga_require_env PUBLISH_PUB_DEV'));
  expect(script, contains('ga_require_env GH_TOKEN'));
  expect(script, contains('ga_require_env PUBLIC_REPOSITORY'));
  expect(script, contains('ga_require_env DOCS_REPOSITORY'));
  expect(script, contains('ga_require_env DOCS_URL'));
  expect(script, isNot(contains('GITHUB_SHA')));
  expect(script, isNot(contains('RUNNER_TEMP')));

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
  expect('$main\n$script', isNot(contains('git merge')));
  expect('$main\n$script', isNot(contains('git push --force')));
  expect('$main\n$script', isNot(contains('--skip-validation')));

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
    checkWorkflow(internal, release, public);
  });

  test('floating action pin mutation fails', () {
    if (internal.isEmpty) return;
    final bad = internal.replaceFirst(
      RegExp(r'actions/checkout@[0-9a-f]{40}'),
      'actions/checkout@v4',
    );
    expect(
      () => checkWorkflow(bad, release, public),
      throwsA(isA<TestFailure>()),
    );
  });

  test('publication shortcut mutation fails', () {
    if (internal.isEmpty) return;
    final bad = internal.replaceFirst(
      'publish_sdk_flutter:\n    needs: '
          '[secret_detection, offline_test, example_android, example_ios, live_test, pub_package]',
      'publish_sdk_flutter:\n    needs: offline_test',
    );
    expect(
      () => checkWorkflow(bad, release, public),
      throwsA(isA<TestFailure>()),
    );
  });

  test('source export mutation fails', () {
    if (internal.isEmpty) return;
    final bad = release.replaceFirst(
      'run tool/release_manifest.dart export "\$export_dir"',
      'run tool/release_manifest.dart check',
    );
    expect(
      () => checkWorkflow(internal, bad, public),
      throwsA(isA<TestFailure>()),
    );
  });

  test('stored publication token mutation fails', () {
    if (internal.isEmpty) return;
    final bad = '$public\n      PUB_TOKEN: \${{ secrets.PUB_TOKEN }}\n';
    expect(
      () => checkWorkflow(internal, release, bad),
      throwsA(isA<TestFailure>()),
    );
  });
}
