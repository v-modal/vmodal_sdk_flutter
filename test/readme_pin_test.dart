import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('public production installation uses immutable version pins', () {
    final readme = File('README.md').readAsStringSync();
    final pubspec = File('pubspec.yaml').readAsStringSync();
    final section = RegExp(
      r'## Start in minutes([\s\S]*?)## Search video',
    ).firstMatch(readme)?.group(1);

    expect(section, isNotNull);
    expect(section, isNot(contains('ref: main')));
    expect(section, contains('main` branch is suitable for evaluation'));
    expect(section, contains('full 40-character commit SHA'));

    final version = RegExp(
      r'^version:\s*([^\s]+)',
      multiLine: true,
    ).firstMatch(pubspec)!.group(1);
    final tag = RegExp(r'ref:\s*v([^\s]+)').firstMatch(section!)?.group(1);
    final published = RegExp(
      r'vmodal_sdk_flutter:\s*([^\s]+)',
    ).firstMatch(section)?.group(1);
    expect(published, isNotNull);
    if (tag != null) expect(tag, published);
    if (published != version) {
      expect(section, contains('**$version source release**'));
      expect(section, contains('do not contain these additions'));
      expect(section, contains('does not publish `$version` to pub.dev'));
    }
  });
}
