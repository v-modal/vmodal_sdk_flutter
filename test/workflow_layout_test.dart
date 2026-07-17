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

void checkWorkflow(String main, String tagged) {
  const releaseOnly =
      "if: \${{ github.event_name == 'workflow_dispatch' && (inputs.publish_sdk_flutter || inputs.publish_pub_dev) }}";
  expect(main, contains('name: sdk_flutter_test_release'));
  expect(main, contains('publish_sdk_flutter:'));
  expect(main, contains('publish_pub_dev:'));
  expect(main, contains('default: true'));
  expect(main, contains('group: sdk_flutter_release_\${{ github.ref }}'));
  expect(main, contains('WORKDIR: uinterface/sdk_flutter'));
  expect(main, contains('RELEASE_SHA: \${{ github.sha }}'));
  expect(
    main,
    contains('secret_detection:\n    $releaseOnly\n    runs-on: ubuntu-latest'),
  );
  expect(main, contains('offline_test:\n    runs-on: ubuntu-latest'));
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
  expect(main, contains('if: \${{ inputs.publish_pub_dev }}'));
  expect(main, contains('environment: sdk-flutter-production'));
  expect(main, contains('gitleaks_'));
  expect(main, contains('--source "\$WORKDIR"'));
  expect(main, isNot(contains('--log-opts=')));
  expect(main, contains('SHA256SUMS'));
  expect(main, contains('SOURCE_MANIFEST.sha256'));
  expect(main, contains('RELEASE_TOKEN: \${{ secrets.GH_TOKEN }}'));
  expect(main, isNot(contains('FLUTTER_SDK_APP_')));
  expect(main, contains('git push --atomic'));
  expect(main, contains('for attempt in {1..30}'));
  expect(main, contains('https://pub.dev/api/packages/vmodal_sdk_flutter'));

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

  test('stored publication token mutation fails', () {
    if (internal.isEmpty) return;
    final bad = '$public\n      PUB_TOKEN: \${{ secrets.PUB_TOKEN }}\n';
    expect(() => checkWorkflow(internal, bad), throwsA(isA<TestFailure>()));
  });
}
