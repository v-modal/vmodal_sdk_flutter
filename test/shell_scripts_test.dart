import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

const scripts = <String>[
  'install.sh',
  'build.sh',
  'run.sh',
  'test.sh',
  'env.sh',
  'security_check.sh',
];

void main() {
  test(
    'all shell scripts have valid syntax and executable dispatchers',
    () async {
      for (final path in scripts) {
        expect(File(path).existsSync(), isTrue, reason: path);
        final syntax = await Process.run('bash', <String>['-n', path]);
        expect(syntax.exitCode, 0, reason: '$path: ${syntax.stderr}');
        final help = await Process.run('bash', <String>[path, 'help']);
        expect(help.exitCode, 0, reason: '$path: ${help.stderr}');
        expect(help.stdout, contains('Usage'));
        final bad = await Process.run('bash', <String>[path, 'not-a-command']);
        expect(bad.exitCode, isNot(0));
      }
    },
  );

  test(
    'env.sh is source-only, idempotent, and preserves explicit values',
    () async {
      const sentinel = 'sdk-secret-sentinel';
      final result = await Process.run('bash', <String>[
        '-c',
        'VMODAL_API_KEY=$sentinel; source env.sh; sdk_env_live; '
            'test "\$VMODAL_API_KEY" = "$sentinel"; sdk_env_live',
      ]);
      expect(result.exitCode, 0, reason: '${result.stderr}');
      expect('${result.stdout}${result.stderr}', isNot(contains(sentinel)));
    },
  );

  test('local helpers cannot publish', () {
    for (final path in scripts.where(
      (String path) => path != 'security_check.sh',
    )) {
      final text = File(path).readAsStringSync();
      expect(text, isNot(contains('pub publish --force')), reason: path);
      expect(text, isNot(contains('--skip-validation')), reason: path);
      expect(text, isNot(contains('git merge')), reason: path);
    }
  });

  test('security commands and fixed all ordering are registered', () {
    final text = File('security_check.sh').readAsStringSync();
    for (final command in <String>[
      'workflow',
      'toolchain',
      'version',
      'license',
      'package',
      'secrets',
      'all',
    ]) {
      expect(text, contains('$command)'));
    }
    final body = RegExp(
      r'sdk_security_all\(\) \{([\s\S]*?)\n\}',
    ).firstMatch(text)!.group(1)!;
    var offset = -1;
    for (final call in <String>[
      'sdk_security_workflow',
      'sdk_security_toolchain',
      'sdk_security_version',
      'sdk_security_license',
      'sdk_security_package',
      'sdk_security_secrets',
    ]) {
      final next = body.indexOf(call);
      expect(next, greaterThan(offset), reason: call);
      offset = next;
    }
  });
}
