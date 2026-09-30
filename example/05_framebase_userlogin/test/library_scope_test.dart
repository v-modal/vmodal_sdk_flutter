import 'package:flutter_test/flutter_test.dart';
import 'package:framebase/user/library_scope.dart';

void main() {
  test('opaque scope is returned byte-for-byte without a legacy prefix', () {
    const scope = 'scope_7K3A';
    expect(validateLibraryScope(scope), same(scope));
    expect(validateLibraryScope(scope), scope);
    expect(scope, isNot(startsWith('framebase_streets__user_')));
  });

  test('invalid scopes fail closed without trimming or sanitizing', () {
    for (final scope in [
      null,
      '',
      ' ',
      ' scope_7K3A',
      'scope_7K3A ',
      'scope/7K3A',
      '../scope_7K3A',
      'scope-7K3A',
      'scope.7K3A',
      'scope:7K3A',
      'scopé_7K3A',
      'a' * 81,
    ]) {
      expect(
        () => validateLibraryScope(scope),
        throwsA(isA<InvalidLibraryScope>()),
        reason: 'invalid scope: $scope',
      );
    }
    expect(validateLibraryScope('a' * 80), 'a' * 80);
  });
}
